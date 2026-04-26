# AudioBridge HAL Driver

The driver is a fork of [BlackHole](https://github.com/ExistentialAudio/BlackHole) (GPL-3.0)
with branding patches applied (`audiobridge-branding.patch`).

- Bundle ID: `design.publicworks.AudioBridge`
- Manufacturer: `PUBLIC WORKS`
- Devices exposed: `AudioBridge 2ch`, `AudioBridge 16ch`, `AudioBridge 24ch`
- Device UIDs: `AudioBridge2ch_UID`, `AudioBridge16ch_UID`, `AudioBridge24ch_UID`
- Installs to: `/Library/Audio/Plug-Ins/HAL/AudioBridge.driver`

## Distribution

The signed installer is at `dist/AudioBridge-Driver-2.2.0-signed.pkg`.
Double-click to install; coreaudiod restarts automatically via postinstall.

## Rebuilding

```bash
./Driver/build.sh
```

This clones BlackHole, applies the branding patch, builds a universal binary,
codesigns with Developer ID, and produces a signed installer pkg.
