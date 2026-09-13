#!/usr/bin/env python3
"""A fake Switch that speaks the SysDVR protocol.

Exists so the client can be proven end to end without the console powered on: it
performs the same handshake, frames packets the same way, and feeds real H.264 that
ffmpeg produced. If Kagami shows a picture from this, the protocol, the decoder and
the render path are all correct, and only the console itself is untested.

    python3 Tools/fake-console.py            # serve video and audio
    python3 Tools/fake-console.py --once     # exit after one client disconnects
"""

import argparse
import math
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

VIDEO_PORT = 9911
AUDIO_PORT = 9922

HELLO = b"SysDVR|03\x00"
REQUEST_MAGIC = 0xAAAAAAAA
PACKET_MAGIC = 0xCCCCCCCC
HANDSHAKE_OK = 6

FLAG_VIDEO = 1 << 0
FLAG_AUDIO = 1 << 1

WIDTH, HEIGHT, FPS = 1280, 720, 30
SAMPLE_RATE, CHANNELS = 48000, 2
AUDIO_PAYLOAD = 0x1000


def build_test_video(seconds: int, gop: int, motion: str, bitrate_kbps: int | None) -> bytes:
    """A moving colour pattern in Annex-B H.264, parameter sets on every keyframe.

    `gop` sets the IDR interval in frames (the real console's is unmeasured; the
    plan's fixtures assume a long one). `motion="noise"` adds per-pixel noise on top
    of the test pattern so P-frames carry real entropy instead of near-empty skip
    blocks, closer to a busy game scene than the default flat pattern.
    """
    out = os.path.join(tempfile.mkdtemp(), "pattern.h264")
    source = f"testsrc2=size={WIDTH}x{HEIGHT}:rate={FPS}"
    if motion == "noise":
        source += ",noise=alls=60:allf=t"
    args = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", source,
        "-t", str(seconds),
        "-c:v", "libx264", "-profile:v", "main", "-preset", "ultrafast",
        "-tune", "zerolatency", "-g", str(gop), "-pix_fmt", "yuv420p",
    ]
    if bitrate_kbps:
        args += ["-b:v", f"{bitrate_kbps}k", "-maxrate", f"{bitrate_kbps}k",
                  "-bufsize", f"{bitrate_kbps}k"]
    args += [
        # Without this libx264's threaded encoder row-slices each picture — one NAL
        # per thread, not per frame — and the access-unit splitter below would treat
        # every slice as its own frame, corrupting the stream it hands to the client.
        "-x264-params", "slices=1:sliced-threads=0",
        # The console injects SPS/PPS ahead of each keyframe when the client asks;
        # dump_extra is how ffmpeg reproduces that.
        "-bsf:v", "dump_extra",
        "-f", "h264", out,
    ]
    subprocess.run(args, check=True)
    return open(out, "rb").read()


def split_access_units(stream: bytes) -> list[bytes]:
    """Cuts an Annex-B stream into one buffer per frame.

    A new access unit starts at the first parameter set or slice that follows a slice —
    the same rule the console's encoder applies when it hands SysDVR a frame.
    """
    starts = []
    i = 0
    while i < len(stream) - 3:
        if stream[i] == 0 and stream[i + 1] == 0:
            if stream[i + 2] == 1:
                starts.append((i, i + 3))
                i += 3
                continue
            if i + 3 < len(stream) and stream[i + 2] == 0 and stream[i + 3] == 1:
                starts.append((i, i + 4))
                i += 4
                continue
        i += 1

    units = []
    current = None
    seen_slice = False
    for n, (code, payload) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(stream)
        nal_type = stream[payload] & 0x1F
        is_slice = nal_type in (1, 5)

        if current is None:
            current = code
        elif seen_slice and (is_slice or nal_type in (7, 8)):
            units.append(stream[current:code])
            current = code
            seen_slice = False

        seen_slice = seen_slice or is_slice
        if n + 1 == len(starts):
            units.append(stream[current:end])
    return units


def build_test_audio(seconds: int) -> bytes:
    """A quiet 440 Hz tone: audible enough to prove the path, gentle enough to leave on."""
    frames = SAMPLE_RATE * seconds
    samples = bytearray()
    for n in range(frames):
        value = int(3000 * math.sin(2 * math.pi * 440 * n / SAMPLE_RATE))
        samples += struct.pack("<hh", value, value)
    return bytes(samples)


def handshake(conn: socket.socket) -> tuple[bool, bool]:
    """Runs the console's half. Returns which streams the client asked for."""
    conn.sendall(HELLO)

    request = recv_exactly(conn, 16)
    magic, version, meta, _video_flags, _batching, _features = struct.unpack("<IHBBBB", request[:10])
    if magic != REQUEST_MAGIC:
        raise ValueError(f"bad request magic {magic:08x}")

    # Protocol 3 answers with 72 bytes; the verdict is the first word either way.
    conn.sendall(struct.pack("<I", HANDSHAKE_OK) + b"\x00" * 68)
    return bool(meta & FLAG_VIDEO), bool(meta & FLAG_AUDIO)


def recv_exactly(conn: socket.socket, count: int) -> bytes:
    buffer = b""
    while len(buffer) < count:
        chunk = conn.recv(count - len(buffer))
        if not chunk:
            raise ConnectionError("client went away")
        buffer += chunk
    return buffer


def send_packet(
    conn: socket.socket, payload: bytes, flags: int, timestamp_us: int
) -> None:
    header = struct.pack("<IiQBB", PACKET_MAGIC, len(payload), timestamp_us, flags, 0)
    conn.sendall(header + payload)


def serve(port: int, worker, once: bool) -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", port))
    server.listen(1)
    print(f"listening on {port}")

    while True:
        conn, address = server.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print(f"[{port}] client from {address[0]}")
        try:
            wants_video, wants_audio = handshake(conn)
            worker(conn, wants_video, wants_audio)
        except (ConnectionError, OSError, ValueError) as error:
            print(f"[{port}] disconnected: {error}")
        finally:
            conn.close()
        if once:
            return


def next_stall_deadline(stall_every: float | None) -> float | None:
    return stall_every if stall_every else None


def apply_stall(elapsed: float, next_at: float | None, stall_ms: float, stall_every: float) -> float | None:
    """Sleeps out one stall when `elapsed` reaches `next_at`, returns the next deadline.

    The pacing loops below compute each send's target time as `start + n * period`
    against the fixed origin `start`, never against the previous send. So a stall
    sleep does not shift later targets — it just makes `time.monotonic()` run past
    several of them at once, and the loop's own `max(0, target - now)` naturally
    sends the whole backlog back to back once the stall ends. This is what
    reproduces a Wi-Fi drain-and-burst without a separate burst code path.
    """
    if next_at is None or elapsed < next_at:
        return next_at
    time.sleep(stall_ms / 1000)
    return next_at + stall_every


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=10, help="length of the loop")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--gop", type=int, default=FPS,
                         help="IDR interval in frames (default: 1s, matching the old fixture)")
    parser.add_argument("--motion", choices=("plain", "noise"), default="plain",
                         help="'noise' adds per-pixel entropy so P-frames are not near-empty")
    parser.add_argument("--bitrate", type=int, default=6000, metavar="KBPS",
                         help="caps the encoder to a target bitrate in kbps (default: 6000, "
                              "close to the ~4.8 Mbps measured on real hardware; pass 0 for "
                              "an uncapped encode). With --motion noise, an uncapped encode's "
                              "IDR frames exceed SysDVRProtocol.maxPayloadSize (0x54000 "
                              "bytes) because noise barely compresses, which the real client "
                              "would also refuse as a corrupt packet")
    parser.add_argument("--stall-ms", type=float, default=None,
                         help="pause sending for this many ms every --stall-every seconds")
    parser.add_argument("--stall-every", type=float, default=None,
                         help="seconds between stalls; requires --stall-ms")
    args = parser.parse_args()
    if (args.stall_ms is None) != (args.stall_every is None):
        parser.error("--stall-ms and --stall-every must be given together")

    print("building test media with ffmpeg...")
    frames = split_access_units(build_test_video(args.seconds, args.gop, args.motion, args.bitrate))
    tone = build_test_audio(args.seconds)
    print(f"{len(frames)} frames, {len(tone) // 1024} KiB of audio")

    def video_worker(conn, wants_video, _wants_audio):
        if not wants_video:
            return
        start = time.monotonic()
        index = 0
        next_stall = next_stall_deadline(args.stall_every)
        while True:
            if next_stall is not None:
                next_stall = apply_stall(time.monotonic() - start, next_stall, args.stall_ms, args.stall_every)
            frame = frames[index % len(frames)]
            send_packet(conn, frame, FLAG_VIDEO, time.monotonic_ns() // 1000)
            index += 1
            # Pace against a fixed origin so the stream does not drift late.
            target = start + index / FPS
            time.sleep(max(0, target - time.monotonic()))

    def audio_worker(conn, _wants_video, wants_audio):
        if not wants_audio:
            return
        start = time.monotonic()
        offset = 0
        chunks = 0
        next_stall = next_stall_deadline(args.stall_every)
        while True:
            if next_stall is not None:
                next_stall = apply_stall(time.monotonic() - start, next_stall, args.stall_ms, args.stall_every)
            chunk = tone[offset:offset + AUDIO_PAYLOAD]
            if len(chunk) < AUDIO_PAYLOAD:
                offset = 0
                continue
            send_packet(conn, chunk, FLAG_AUDIO, time.monotonic_ns() // 1000)
            offset += AUDIO_PAYLOAD
            chunks += 1
            seconds_per_chunk = (AUDIO_PAYLOAD / (CHANNELS * 2)) / SAMPLE_RATE
            target = start + chunks * seconds_per_chunk
            time.sleep(max(0, target - time.monotonic()))

    threads = [
        threading.Thread(target=serve, args=(VIDEO_PORT, video_worker, args.once), daemon=True),
        threading.Thread(target=serve, args=(AUDIO_PORT, audio_worker, args.once), daemon=True),
    ]
    for thread in threads:
        thread.start()
    try:
        while any(t.is_alive() for t in threads):
            time.sleep(0.3)
    except KeyboardInterrupt:
        print("\nstopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
