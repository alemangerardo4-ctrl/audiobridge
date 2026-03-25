# AudioBridge

Menu bar app for seamless audio routing on macOS. Record system audio, create virtual devices, route between applications with zero latency.

## Features

- **System Audio Capture** - Record from browser, Spotify, YouTube, any app
- **Virtual Audio Devices** - 2ch, 16ch, and 24ch routing
- **Zero Latency** - Direct CoreAudio passthrough
- **Menu Bar Control** - Simple toggle and quick profiles

## Installation

1. Download `AudioBridge-1.0.0.pkg` from [Releases](../../releases) **(96 KB)**
2. Double-click to install
3. Grant Audio Extension permissions:
   - System Settings → Privacy & Security
   - Approve "AudioBridge" extension
4. Restart your Mac
5. AudioBridge appears in menu bar

## Menu Bar App

The AudioBridge menu bar app (`AudioBridgeApp/`) provides:

- **Enable AudioBridge toggle** — detects the HAL driver via CoreAudio
- **Quick Profiles** — one-click input routing for common workflows:
  - Podcast Recording → AudioBridge 2ch
  - Music Production → AudioBridge 16ch
  - Streaming → AudioBridge 2ch
  - Screen Recording → AudioBridge 2ch
- **Open Audio MIDI Setup** — shortcut to Apple's routing utility
- **About / Quit**

No dock icon (`LSUIElement = true`). Lives entirely in the menu bar.

### Building the Menu Bar App

Requires Xcode Command Line Tools and macOS 13+.

```bash
swift build -c release
```

Or open in Xcode via `Package.swift`.

## Usage

### Basic Recording

1. Click AudioBridge icon in menu bar
2. Select a **Quick Profile** or manually set input in your DAW
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

- **Podcast Recording** — route Discord/Zoom audio into your DAW
- **Music Production** — send audio between DAWs and plugins
- **Streaming** — combine mic + desktop audio into OBS
- **Screen Recording** — capture system audio in QuickTime

## System Requirements

- **macOS:** 11.0 (Big Sur) or later (menu bar app requires 13+)
- **Architecture:** Intel & Apple Silicon (Universal)
- **DAW:** Any CoreAudio-compatible app
- **Size:** 96 KB (installer)

## Technical Details

- Built with Swift + CoreAudio
- Virtual audio driver using Audio Server Plugin
- Zero CPU overhead (hardware passthrough)
- Menu bar app uses `NSStatusItem` + CoreAudio device enumeration

## Troubleshooting

**AudioBridge not appearing in DAW?**
- Restart your Mac after installation
- Check System Settings → Privacy & Security → Extensions
- Verify audio extension is approved

**No audio routing?**
- Verify "AudioBridge 2ch" is selected in DAW input
- Check Audio MIDI Setup app (menu bar → Open Audio MIDI Setup)

## Version

**Current:** 1.0.0
**Released:** March 2026

## License

Based on BlackHole by [Existential Audio Inc.](https://existential.audio/) — GPL-3.0.
See [ATTRIBUTION.md](ATTRIBUTION.md) for details.

---

**Part of [PUBLIC WORKS](https://publicworks.design) - Open source audio tools for creators.**
