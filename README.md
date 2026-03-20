# AudioBridge

Menu bar app for seamless audio routing on macOS. Record system audio, create virtual devices, route between applications with zero latency.

## Features

- **System Audio Capture** - Record from browser, Spotify, YouTube, any app
- **Virtual Audio Devices** - 2ch, 16ch, and 24ch routing
- **Zero Latency** - Direct CoreAudio passthrough
- **Menu Bar Control** - Simple toggle for recording

## Installation

1. Download `AudioBridge-1.0.0.pkg` from [Releases](../../releases) **(96 KB)**
2. Double-click to install
3. Grant Audio Extension permissions:
   - System Settings → Privacy & Security
   - Approve "AudioBridge" extension
4. Restart your Mac
5. AudioBridge appears in menu bar

## Usage

### Basic Recording

1. Click AudioBridge icon in menu bar
2. Click "Start Recording"
3. Open your DAW (Logic, Ableton, Pro Tools, etc.)
4. Select **"AudioBridge 2ch"** as input device
5. System audio now routes to your DAW

### Virtual Device Setup

**In your DAW:**
- Input: AudioBridge 2ch (for system audio)
- Output: Your normal output device

**AudioBridge automatically creates:**
- AudioBridge 2ch (stereo)
- AudioBridge 16ch (multi-channel)
- AudioBridge 24ch (full routing)

## Use Cases

- **Sample System Audio** - Capture sounds from any app
- **Record Streams** - Archive Spotify, YouTube, podcasts
- **Audio Hijacking** - Route app audio into your DAW
- **Live Looping** - Capture and process in real-time

## System Requirements

- **macOS:** 11.0 (Big Sur) or later
- **Architecture:** Intel & Apple Silicon (Universal)
- **DAW:** Any CoreAudio-compatible app
- **Size:** 96 KB (installer)

## Technical Details

- Built with Swift + CoreAudio
- Virtual audio driver using Audio Server Plugin
- Zero CPU overhead (hardware passthrough)
- Signed and notarized for macOS

## Troubleshooting

**AudioBridge not appearing in DAW?**
- Restart your Mac after installation
- Check System Settings → Privacy & Security → Extensions
- Verify audio extension is approved

**No audio routing?**
- Click menu bar icon to toggle recording ON
- Verify "Audio Bridge 2ch" selected in DAW input
- Check Audio MIDI Setup app (search in Spotlight)

## Version

**Current:** 1.0.0  
**Released:** March 2026

## License

Open source - MIT License

---

**Part of [PUBLIC WORKS](https://publicworks.design) - Open source audio tools for creators.**

**Download:** [AudioBridge-1.0.0.pkg](https://publicworks.design/downloads/AudioBridge-1.0.0.pkg) (96 KB)
