# FlipScroll: scroll reverser for Mac

FlipScroll is a free macOS menu bar app that reverses scroll direction separately for each axis and each device. Your mouse can scroll the classic way, both vertically **and horizontally**, while your trackpad keeps natural scrolling.

**Download:** [FlipScroll.zip](https://github.com/develant/flipscroll/releases/latest/download/FlipScroll.zip) · **Website:** https://flipscroll.brickandclick.tech · [Buy me a coffee](https://buymeacoffee.com/aleant)

## Features

- Reverse vertical and horizontal scrolling independently
- Separate settings for mouse and trackpad (Magic Mouse detected by finger count)
- Momentum scrolling keeps the direction of the device that started it
- Launch at login, no network access, no analytics
- Universal binary, macOS 13 or later

## Build

```sh
./build.sh            # build into build/FlipScroll.app
./build.sh --install  # build and copy into /Applications
./build.sh --release  # sign with Developer ID, notarize, zip to dist/FlipScroll.zip
swift Tools/make_icon.swift   # regenerate Resources/AppIcon.icns
```

`--release` needs a Developer ID Application certificate in the keychain and `.env.release` (see `.env.release.example`).

## Website

The landing page lives in `site/` and deploys to Firebase Hosting:

```sh
firebase deploy --only hosting:flipscroll --project brickandclick
```
