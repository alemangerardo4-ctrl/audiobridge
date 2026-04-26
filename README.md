# AudioBridge

Menu bar app for seamless audio routing on macOS. Record system audio, create virtual devices, route between applications with zero latency.

## Features

- **System Audio Capture** - Record from browser, Spotify, YouTube, any app
- **Virtual Audio Devices** - 2ch, 16ch, and 24ch routing
- **Zero Latency** - Direct CoreAudio passthrough
- **Menu Bar Control** - Simple toggle and quick profiles

## Installation

1. Install the driver: open `dist/AudioBridge-Driver-2.2.0-signed.pkg` and follow the prompts
2. Restart your Mac (HAL plugins are loaded at coreaudiod startup; the postinstall kicks coreaudiod but a reboot is the reliable path)
3. Run the menu bar app: extract `dist/AudioBridge-2.2.0.zip` and move `AudioBridge.app` to `/Applications`

The driver installs to `/Library/Audio/Plug-Ins/HAL/AudioBridge.driver` (bundle ID `design.publicworks.AudioBridge`).

## Menu Bar App

The AudioBridge menu bar app (`AudioBridgeApp/`) provides:

- **Driver detection** — checks for the HAL driver by device UID (`AudioBridge2ch_UID`, etc.) and live-updates when the driver appears or disappears
- **Quick Profiles** — one-click input routing for common workflows:
  - Podcast Recording → AudioBridge 2ch
  - Music Production → AudioBridge 16ch
  - Streaming → AudioBridge 2ch
  - Screen Recording → AudioBridge 2ch
- **Voice + System Audio** — toggles a CoreAudio aggregate input that combines the current default mic with AudioBridge 2ch and sets it as default input. DAWs see one device with mic + system-audio channels side-by-side
- **Monitor + Record** — toggles a multi-output aggregate (current speakers + AudioBridge) so you keep listening while a DAW records system audio
- **Open Audio MIDI Setup** — shortcut to Apple's routing utility
- **Install Driver…** — opens the bundled `.pkg`
- **About / Quit**

No dock icon (`LSUIElement = true`). Lives entirely in the menu bar.

### Building the Menu Bar App

Requires Xcode Command Line Tools and macOS 13+.

```bash
./build-app.sh
```

Produces a signed universal (arm64 + x86_64) `dist/AudioBridge-<version>.zip`. The script stages the bundle in `/tmp` because the iCloud-synced repo path adds xattrs that codesign rejects.

### Building the Driver

The driver source is a fork of [BlackHole](https://github.com/ExistentialAudio/BlackHole) with branding patches in `Driver/audiobridge-branding.patch`. To rebuild from scratch:

```bash
./Driver/build.sh
```

See `Driver/README.md` for details.

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

**Current:** 2.2.0
**Released:** April 2026

## License

Based on BlackHole by [Existential Audio Inc.](https://existential.audio/) — GPL-3.0.
See [ATTRIBUTION.md](ATTRIBUTION.md) for details.

---

**Part of [PUBLIC WORKS](https://publicworks.design) - Open source audio tools for creators.**
