# SnapStack

A native macOS screenshot utility maintained by [seoune-prog](https://github.com/seoune-prog).

## Features

- Area, window (Space during area selection), and display capture
- Floating thumbnails, drag and drop, capture history, and pinning
- Annotation editor and Korean/English OCR using Apple Vision
- Local storage with configurable retention and keyboard shortcuts

## Requirements and build

macOS 15 or later. Building requires Swift and the macOS 26 SDK for the optional Liquid Glass APIs.

```sh
bash build.sh --no-install   # Build Apple Silicon app without installing or launching
bash build.sh                # Replace /Applications/SnapStack.app and launch
bash make-dmg.sh             # Build Intel + Apple Silicon distribution image
```

Bundle identifier: `com.seoune.snapstack`. Changing from the old identifier may require granting screen recording permission and configuring preferences again.

## Data handling

Captures remain local; OCR uses Apple Vision. Screen recording permission is required. Default retention is **one day**: older captures are permanently deleted when cleanup runs. Deleting captures and exceeding the daily limit also removes files permanently, without moving them to Trash. Save a copy elsewhere for long-term storage.

Builds use ad-hoc signing. Developer ID signing and notarization are not configured. No third-party license is granted by this repository; a license has not yet been selected.

## Development

`SNAPSTACK_ROOT` overrides capture storage for isolated testing. `SNAPSTACK_QA` enables development checks; avoid using it with real capture history. QA OCR can write recognized text to the local app log.
