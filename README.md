# MicBar

A macOS menu bar app that shows which microphone is actively capturing audio and which apps are using it.

## Features

- Shows the active input device name in the menu bar when a mic is capturing
- Displays a quiet mic icon when no microphone is in use
- Detects which apps are using the microphone (via system log attribution)
- Input device switcher — change your default mic from the dropdown
- Launch at Login support
- Polls every 2 seconds for device state changes

## Requirements

- macOS 14 (Sonoma) or later
- For app detection: Full Disk Access (to read TCC database as fallback)

## Building

```bash
# Build and create .app bundle
./bundle.sh

# Or build manually
swift build -c release
```

## Installation

```bash
cp -r MicBar.app /Applications/
```

Or just run directly:

```bash
open MicBar.app
```

## How It Works

MicBar uses three layers of detection to identify which apps are using your microphone:

1. **System log attribution** (primary) — queries `tccd` logs for recent microphone access events, giving exact PIDs
2. **CoreAudio private APIs** — attempts to find process ownership of audio taps on active devices
3. **TCC heuristic** (fallback) — cross-references running apps with microphone permission grants

For device detection, it scans all input devices via CoreAudio HAL for active input streams, not just the system default — so it correctly identifies non-default devices used directly by apps like Zoom or Meet.

## License

MIT
