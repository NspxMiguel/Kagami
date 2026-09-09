# Kagami

Your Nintendo Switch's screen, on your Apple Vision Pro.

<img src="docs/screenshot.png" alt="Kagami showing a live test pattern" width="640">

## What it is

Kagami is a native visionOS app that connects directly to a Switch running
Atmosphère with [SysDVR](https://github.com/exelix11/SysDVR) installed, over your
local network — no capture card, no Mac or PC in the middle, no cost.

SysDVR's TCP Bridge mode streams the console's own H.264 video and PCM audio.
Kagami speaks that protocol itself: it decodes the video with VideoToolbox (the
same hardware decoder the OS uses everywhere else) and renders it as a floating
window in space.

The one thing it does beyond mirroring the screen: the space around the picture
picks up the average colour of whatever is on it, like bias lighting behind a
TV. A cave level dims the room; a snow field brightens it.

## Requirements

On the Switch:

1. [Atmosphère](https://github.com/Atmosphere-NX/Atmosphere), with
   [SysDVR](https://github.com/exelix11/SysDVR) installed as a sysmodule.
2. SysDVR set to **Simple network mode (TCP)**, then reboot the console.
3. Both devices on the same network — wired beats Wi-Fi for this.

On the headset: visionOS 26 or later.

## Building

```bash
xcodegen generate
open Kagami.xcodeproj
```

Build and run the `Kagami` scheme on your Vision Pro or the visionOS simulator.

## How it works

- `Sources/Protocol/` — the SysDVR wire format: handshake, packet framing, and the
  Annex-B ↔ length-prefixed repacking VideoToolbox needs. Transcribed from the
  reference client, not guessed.
- `Sources/Media/` — H.264 decode (VideoToolbox) and PCM playback (AVAudioEngine).
- `Sources/UI/` — the interface: the connect screen, the floating screen, and the
  ambient light.
- `Tools/fake-console.py` — a stand-in SysDVR server for testing without a Switch
  powered on. It speaks the exact same handshake and packet framing, so if Kagami
  shows a picture from it, the protocol and decode path are proven end to end.

## Testing without a console

```bash
python3 Tools/fake-console.py
```

This serves a real H.264 test pattern on ports 9911/9922, exactly as SysDVR would.
Point Kagami at `127.0.0.1` (the visionOS Simulator shares the Mac's network stack)
to see it decode and render.
