# MeetingRecorder

A minimal macOS menu bar app that records Zoom (or any) meetings with **one click** — no host permission needed, no virtual audio drivers, no configuration.

## Features

- Records **screen + system audio + microphone** simultaneously
- Pick any **screen** or capture a **specific app** (e.g. Zoom) regardless of focus
- Saves as MP4 to your Desktop, opens Finder automatically when done
- Lives in the menu bar — out of the way until you need it
- No BlackHole, no Audio MIDI Setup, no virtual audio driver required

## Requirements

- macOS 13+ (Ventura or later)
- [ffmpeg](https://evermeet.cx/ffmpeg/) at `~/.local/bin/ffmpeg` (or update the path in `App.swift`)
- Screen Recording + Microphone permission (prompted on first use)

## Build

```bash
git clone https://github.com/miguelAngelo1999/MeetingRecorder
cd MeetingRecorder

swiftc App.swift \
  -o MeetingRecorder \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework ScreenCaptureKit \
  -framework AVFoundation

# Create app bundle
mkdir -p MeetingRecorder.app/Contents/MacOS
mkdir -p MeetingRecorder.app/Contents/Resources
cp MeetingRecorder MeetingRecorder.app/Contents/MacOS/
cp Info.plist MeetingRecorder.app/Contents/

# Generate icon
python3 make_icon.py

# Sign and install
codesign --force --deep -s - --entitlements entitlements.plist MeetingRecorder.app
cp -r MeetingRecorder.app /Applications/
open /Applications/MeetingRecorder.app
```

## Usage

1. Click the mic icon in the menu bar
2. Choose **Capture** → pick a screen or a specific app (e.g. Zoom)
3. Click **Start Recording**
4. Grant Screen Recording + Microphone permissions when prompted (first run only)
5. Click **Stop Recording** → MP4 saved to Desktop

## How it works

Uses Apple's **ScreenCaptureKit** to capture screen and system audio natively — no virtual audio driver needed. Microphone is captured separately via `AVAudioEngine`. Both audio streams are mixed at the end using ffmpeg.

## Files

| File | Purpose |
|------|---------|
| `App.swift` | Full app source — menu bar UI, screen/app capture, mic recording |
| `Info.plist` | App bundle metadata and privacy descriptions |
| `entitlements.plist` | Audio input entitlement for mic access |
| `make_icon.py` | Generates the app icon programmatically using AppKit |

## License

MIT
