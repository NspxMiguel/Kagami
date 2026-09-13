#!/usr/bin/env python3
"""Passive latency/throughput probe for a live SysDVR TCP Bridge console.

Speaks the exact same wire protocol as Kagami's Swift client (see
Sources/Protocol/SysDVRProtocol.swift and Tools/fake-console.py) but never
decodes or displays anything -- it only times and measures. Use it to find out
whether a bad picture on the headset is caused by the network/console or by
something in the app's own pipeline.

    python3 Tools/latency-probe.py --video --seconds 45
    python3 Tools/latency-probe.py --both --seconds 45

Only one client can hold each port (9911 video, 9922 audio) at a time -- if
the headset app is already connected, this script's connect() call will
either time out or the handshake will hang, and it prints a clear failure
instead of retrying forever.
"""

from __future__ import annotations

import argparse
import socket
import statistics
import struct
import sys
import threading
import time
from dataclasses import dataclass, field

HELLO_SIZE = 10
REQUEST_SIZE = 16
REQUEST_MAGIC = 0xAAAAAAAA
PACKET_MAGIC = 0xCCCCCCCC
HANDSHAKE_OK = 6
MAX_PAYLOAD_SIZE = 0x54000  # sanity bound the client also uses, to detect lost sync

PKT_FLAG_VIDEO = 1 << 0
PKT_FLAG_AUDIO = 1 << 1
PKT_FLAG_DATA = 1 << 2
PKT_FLAG_HASH = 1 << 3
PKT_FLAG_MULTINAL = 1 << 4
PKT_FLAG_ERROR = 1 << 5

VERSION_02 = ord("0") | (ord("2") << 8)
VERSION_03 = ord("0") | (ord("3") << 8)

RECV_CHUNK = 65536
CONNECT_TIMEOUT = 5.0
# A live console streams continuously; if nothing arrives for this long the
# port is almost certainly held by another client (the headset app) rather
# than genuinely idle.
SILENCE_TIMEOUT = 8.0

# Thresholds the app currently uses to drop stale frames (Sources/Session.swift
# and friends) -- kept here so the probe's counts line up with what the app
# would have discarded.
VIDEO_DROP_THRESHOLD_MS = 120.0
AUDIO_DROP_THRESHOLD_MS = 80.0

INTRA_PACKET_STALL_MS = 40.0
INTRA_PACKET_STALL_SEVERE_MS = 100.0

INTER_ARRIVAL_GAP_MS = 100.0
INTER_ARRIVAL_GAP_SEVERE_MS = 200.0


@dataclass
class Chunk:
    """One recv() call while assembling a single packet (header + payload)."""

    arrival_ns: int
    length: int


@dataclass
class PacketRecord:
    arrival_ns: int  # time.monotonic_ns() the instant the LAST payload byte arrived
    timestamp_us: int  # console clock, from the packet header
    size: int  # payload size in bytes (header not included)
    flags: int
    chunks: list[Chunk] = field(default_factory=list)


@dataclass
class StreamResult:
    name: str
    error: str | None = None
    packets: list[PacketRecord] = field(default_factory=list)
    idr_timestamps_us: list[int] = field(default_factory=list)
    sps_count: int = 0
    duration_s: float = 0.0


def recv_tracked(sock: socket.socket, count: int, chunks: list[Chunk] | None) -> bytes:
    """Reads exactly `count` bytes, optionally recording one Chunk per recv() call.

    Splitting a single payload across multiple recv() calls with a visible gap
    between them is the fingerprint of Nagle/delayed-ACK interaction or of the
    sender itself trickling data out slowly -- this is what lets the caller see it.
    """
    buf = bytearray()
    while len(buf) < count:
        piece = sock.recv(min(RECV_CHUNK, count - len(buf)))
        now = time.monotonic_ns()
        if not piece:
            raise ConnectionError("console closed the connection")
        buf += piece
        if chunks is not None:
            chunks.append(Chunk(now, len(piece)))
    return bytes(buf)


def handshake(sock: socket.socket, want_video: bool, want_audio: bool) -> int:
    """Runs the SysDVR handshake. Returns the negotiated protocol version code."""
    hello = recv_tracked(sock, HELLO_SIZE, None)
    if not hello.startswith(b"SysDVR|") or hello[-1:] != b"\x00":
        raise ValueError(f"not a SysDVR hello: {hello!r}")
    version = hello[7] | (hello[8] << 8)  # two ASCII digits, in memory order

    meta = (0b01 if want_video else 0) | (0b10 if want_audio else 0)
    video_flags = 1 << 1  # ask the console to inject SPS/PPS ahead of every keyframe
    audio_batching = 0
    feature_flags = 0
    request = struct.pack(
        "<IHBBBB6x",
        REQUEST_MAGIC,
        version,
        meta,
        video_flags,
        audio_batching,
        feature_flags,
    )
    assert len(request) == REQUEST_SIZE
    sock.sendall(request)

    response_size = 72 if version >= VERSION_03 else 4
    response = recv_tracked(sock, response_size, None)
    (result,) = struct.unpack_from("<I", response, 0)
    if result != HANDSHAKE_OK:
        raise ValueError(f"console refused handshake, result={result}")
    return version


def find_nal_types(payload: bytes) -> set[int]:
    """Scans an Annex-B buffer for start codes and returns the NAL types found."""
    types: set[int] = set()
    i = 0
    n = len(payload)
    while i < n - 3:
        if payload[i] == 0 and payload[i + 1] == 0:
            if payload[i + 2] == 1:
                start = i + 3
            elif i + 3 < n and payload[i + 2] == 0 and payload[i + 3] == 1:
                start = i + 4
            else:
                i += 1
                continue
            if start < n:
                types.add(payload[start] & 0x1F)
            i = start
            continue
        i += 1
    return types


def capture(
    host: str,
    port: int,
    seconds: float,
    want_video: bool,
    want_audio: bool,
    result: StreamResult,
) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(CONNECT_TIMEOUT)
    try:
        sock.connect((host, port))
    except OSError as error:
        result.error = f"connect to {host}:{port} failed: {error}"
        return

    try:
        version = handshake(sock, want_video, want_audio)
    except (OSError, ValueError) as error:
        result.error = f"handshake on port {port} failed: {error}"
        sock.close()
        return

    sock.settimeout(SILENCE_TIMEOUT)
    start = time.monotonic()
    deadline = start + seconds
    try:
        while time.monotonic() < deadline:
            # Header and payload are tracked separately: the interesting stall is
            # a payload splitting across multiple recv() calls with a gap, not the
            # unremarkable fact that the header arrives before the payload.
            header = recv_tracked(sock, 18, None)
            magic, data_size, timestamp_us, flags, _replay_slot = struct.unpack(
                "<IiQBB", header
            )
            if magic != PACKET_MAGIC:
                result.error = f"lost sync after {len(result.packets)} packets: bad magic {magic:#010x}"
                break
            if data_size < 0 or data_size > MAX_PAYLOAD_SIZE:
                result.error = (
                    f"lost sync after {len(result.packets)} packets: "
                    f"implausible payload size {data_size}"
                )
                break

            payload_chunks: list[Chunk] = []
            payload = recv_tracked(sock, data_size, payload_chunks) if data_size else b""
            chunks = payload_chunks
            arrival_ns = time.monotonic_ns()

            if flags & PKT_FLAG_VIDEO and data_size:
                nal_types = find_nal_types(payload)
                if 5 in nal_types:
                    result.idr_timestamps_us.append(timestamp_us)
                if 7 in nal_types:
                    result.sps_count += 1

            result.packets.append(
                PacketRecord(arrival_ns, timestamp_us, data_size, flags, chunks)
            )
    except socket.timeout:
        result.error = (
            (result.error + "; " if result.error else "")
            + f"no data for {SILENCE_TIMEOUT:.0f}s -- port likely held by another client"
        )
    except (OSError, ConnectionError) as error:
        result.error = (result.error + "; " if result.error else "") + str(error)
    finally:
        result.duration_s = time.monotonic() - start
        sock.close()


def percentile(sorted_values: list[float], p: float) -> float | None:
    if not sorted_values:
        return None
    idx = min(len(sorted_values) - 1, int(round(p / 100 * (len(sorted_values) - 1))))
    return sorted_values[idx]


def summarize(result: StreamResult) -> None:
    print(f"\n=== {result.name} ===")
    if result.error:
        print(f"  note: {result.error}")
    packets = result.packets
    if not packets:
        print("  no packets captured")
        return

    total_bytes = sum(18 + p.size for p in packets)
    duration = result.duration_s if result.duration_s > 0 else 1e-9
    print(f"  duration: {duration:.1f} s, packets: {len(packets)}")
    print(f"  packets/s: {len(packets) / duration:.1f}")
    print(f"  Mbps (incl. 18B headers): {total_bytes * 8 / duration / 1e6:.2f}")

    sizes = sorted(p.size for p in packets)
    print(
        f"  payload size bytes -- p50 {percentile(sizes, 50):.0f}  "
        f"p95 {percentile(sizes, 95):.0f}  max {max(sizes):.0f}"
    )

    if result.idr_timestamps_us:
        idr_s = sorted(t / 1e6 for t in result.idr_timestamps_us)
        intervals = [b - a for a, b in zip(idr_s, idr_s[1:])]
        if intervals:
            print(
                f"  IDR interval s -- min {min(intervals):.2f}  "
                f"median {statistics.median(intervals):.2f}  max {max(intervals):.2f}  "
                f"(count {len(idr_s)}, SPS seen {result.sps_count}x)"
            )
        else:
            print(f"  IDR seen once (count {len(idr_s)}), no interval to measure")
    elif any(p.flags & PKT_FLAG_VIDEO for p in packets):
        print("  no IDR (NAL type 5) found in this window")

    arrivals_ns = sorted(p.arrival_ns for p in packets)
    inter_ms = [(b - a) / 1e6 for a, b in zip(arrivals_ns, arrivals_ns[1:])]
    if inter_ms:
        inter_sorted = sorted(inter_ms)
        gaps_100 = sum(1 for g in inter_ms if g > INTER_ARRIVAL_GAP_MS)
        gaps_200 = sum(1 for g in inter_ms if g > INTER_ARRIVAL_GAP_SEVERE_MS)
        print(
            f"  inter-arrival ms -- p50 {percentile(inter_sorted, 50):.1f}  "
            f"p99 {percentile(inter_sorted, 99):.1f}  "
            f"gaps>100ms: {gaps_100}  gaps>200ms: {gaps_200}"
        )

    # Excess delay: (arrival - timestamp) normalized so the best-case packet in
    # this run reads as zero. The console clock and this Mac's monotonic clock
    # have no common epoch, so only the *shape* of this offset over time is
    # meaningful, not its absolute value.
    offsets_s = [(p.arrival_ns / 1e9) - (p.timestamp_us / 1e6) for p in packets]
    floor = min(offsets_s)
    excess_ms = sorted((o - floor) * 1000 for o in offsets_s)
    threshold_ms = (
        AUDIO_DROP_THRESHOLD_MS
        if any(p.flags & PKT_FLAG_AUDIO for p in packets)
        and not any(p.flags & PKT_FLAG_VIDEO for p in packets)
        else VIDEO_DROP_THRESHOLD_MS
    )
    over_80 = sum(1 for e in excess_ms if e > AUDIO_DROP_THRESHOLD_MS)
    over_120 = sum(1 for e in excess_ms if e > VIDEO_DROP_THRESHOLD_MS)
    print(
        f"  excess delay ms -- p50 {percentile(excess_ms, 50):.1f}  "
        f"p95 {percentile(excess_ms, 95):.1f}  p99 {percentile(excess_ms, 99):.1f}  "
        f"max {max(excess_ms):.1f}"
    )
    print(
        f"  excess delay over 80ms: {over_80} ({100 * over_80 / len(excess_ms):.1f}%)  "
        f"over 120ms: {over_120} ({100 * over_120 / len(excess_ms):.1f}%)  "
        f"[this stream's app drop threshold is {threshold_ms:.0f}ms]"
    )

    stall_40 = 0
    stall_100 = 0
    max_stall_ms = 0.0
    for p in packets:
        for a, b in zip(p.chunks, p.chunks[1:]):
            gap_ms = (b.arrival_ns - a.arrival_ns) / 1e6
            if gap_ms > INTRA_PACKET_STALL_MS:
                stall_40 += 1
            if gap_ms > INTRA_PACKET_STALL_SEVERE_MS:
                stall_100 += 1
            max_stall_ms = max(max_stall_ms, gap_ms)
    multi_chunk_packets = sum(1 for p in packets if len(p.chunks) > 1)
    print(
        f"  intra-packet stalls -- payloads split across >1 recv(): {multi_chunk_packets}  "
        f"gaps>40ms: {stall_40}  gaps>100ms: {stall_100}  max gap: {max_stall_ms:.1f}ms"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="10.0.0.67", help="console IP address")
    parser.add_argument("--video-port", type=int, default=9911)
    parser.add_argument("--audio-port", type=int, default=9922)
    parser.add_argument("--seconds", type=float, default=45.0, help="capture length")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--video", action="store_true", help="video stream only")
    mode.add_argument("--audio", action="store_true", help="audio stream only")
    mode.add_argument(
        "--both", action="store_true", help="video and audio together, two sockets"
    )
    args = parser.parse_args()

    want_video = args.video or args.both or not (args.video or args.audio or args.both)
    want_audio = args.audio or args.both

    results: list[tuple[threading.Thread, StreamResult]] = []

    if want_video:
        r = StreamResult(name=f"video ({args.host}:{args.video_port})")
        # Each connection asks the console for exactly the streams it wants on
        # that socket; the console multiplexes internally by port, not by flag,
        # but the handshake still declares intent per SysDVR's own client.
        t = threading.Thread(
            target=capture,
            args=(args.host, args.video_port, args.seconds, True, False, r),
        )
        results.append((t, r))

    if want_audio:
        r = StreamResult(name=f"audio ({args.host}:{args.audio_port})")
        t = threading.Thread(
            target=capture,
            args=(args.host, args.audio_port, args.seconds, False, True, r),
        )
        results.append((t, r))

    print(f"probing {args.host} for {args.seconds:.0f}s ...", file=sys.stderr)
    for t, _ in results:
        t.start()
    for t, _ in results:
        t.join()

    for _, r in results:
        summarize(r)

    return 0


if __name__ == "__main__":
    sys.exit(main())
