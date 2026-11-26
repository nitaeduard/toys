# Toys

Small macOS toys in a single Xcode project. Currently the main one is **Snowfall**.

## Snowfall

A menu-bar app (❄︎) that makes it snow over your desktop. Snow falls over every window, piles up on window tops, desktop widgets, the Dock and desktop icons, and falls off when they move.

- **Piles that follow shapes:** snow builds up along the top of each window and hugs its rounded corners. On desktop icons it follows the icon's real outline. Once a pile is full, extra snow hangs over the front edge until a chunk breaks off.
- **Cascades:** snow knocked off a window tumbles down and can land on the windows below. A bare surface catches most of it; where snow already lies, most of it tumbles on.
- **Moving things shake it off:** moving, resizing, closing, minimising or hiding a window drops its snow. When a window comes to the front, it shakes its snow off as well. Switching Spaces keeps each window's snow for when you come back.
- **Ice and icicles:** snow that lies undisturbed for a couple of minutes starts packing into pale blue ice from the bottom up, and is mostly ice after about 10 minutes. Flakes blown against the side of a window stop there and melt. Their water freezes into icicles at that window's top corners. Ice and icicles break off as shards when the window moves or comes to the front.
- **Ground and Dock:** snow collects in drifts along the bottom of each screen. With Dock snow on, falling snow settles on top of the Dock. Snow knocked off the Dock when you hover over it falls off the screen.
- **The elf:** an elf walks across a screen with a shovel and clears its ground snow away. It comes when the snow there is deeper than half the Dock's height anywhere, or covers more than 70% of the screen's width.
- **Battery-friendly:** the animation pauses while the screens sleep, the Mac is locked, you switch to another user, or Low Power Mode is on.

### Menu

| Item | What it does |
|---|---|
| Clear Snow | Removes all the snow at once |
| Send the Elf | Sends the elf to clear the bottom of every screen now |
| Snow on Dock & Desktop Icons | Turns snow on the Dock and desktop icons on or off. Needs the Accessibility permission |
| Quit Snowfall | Quits Snowfall |

### Permissions

Windows and desktop widgets need no permission: Snowfall only reads their positions. The Dock and desktop icons aren't windows, so their frames come from the Accessibility API. Snowfall asks for that permission once on first launch. You can grant it later in **System Settings › Privacy & Security › Accessibility**, or from the menu.

## Building

Requires **Xcode 27**. The project uses Xcode 27's new project format (`Toys.xcodeproj/project.xcproj`), which older Xcode versions can't open. It targets macOS 26.7.3 or later.

1. Set up signing (one time). Copy the example config and fill in your team ID and bundle ID prefix:

   ```bash
   cp Config/Local.example.xcconfig Config/Local.xcconfig
   ```

   `Config/Local.xcconfig` is git-ignored, so your signing details stay out of the repo.

2. Build and launch Snowfall:

   ```bash
   Scripts/build-snowfall.sh
   ```

   The script finds an Xcode 27 install even if `xcode-select` points to an older one. It builds the Release configuration into `build/DerivedData`, quits any running Snowfall, and opens the new build. Pass `Debug` to build that configuration instead.

### Tests

The `SnowfallTests` target uses Swift Testing. It covers the snow model: pile shapes and capacity, sliding and draping, catching falling snow, and which parts of a pile are hidden behind surfaces in front. The model sources are compiled straight into the test bundle, so the tests don't launch the app.

```bash
DEVELOPER_DIR=/path/to/Xcode27.app/Contents/Developer xcodebuild -project Toys.xcodeproj -scheme SnowfallTests -destination 'platform=macOS' test
```

## Layout

```
Snowfall/            the menu-bar app
  main.swift           app entry point
  AppDelegate.swift    menu, overlay windows per screen, frame loop, polling, pausing
  World.swift          the simulation: flakes, falling clumps, cascades, ground, elves, window tracking
  SnowView.swift       rendering: cached pile tiles, flake/clump/elf sprites
  AXScanner.swift      Dock, desktop icon and widget frames via Accessibility
  IconShapes.swift     measures the outline of each desktop icon or thumbnail
SnowfallModel/       snow model shared by the app and the tests
  Pile.swift           surfaces and their snow height maps
SnowfallTests/       Swift Testing tests for the model
MyApp/               "Toys" target: still the Xcode SwiftUI template, a placeholder
Config/              xcconfig for local signing (example committed, real one git-ignored)
Scripts/             build-snowfall.sh
```

### How Snowfall works

- Each screen gets a transparent, click-through, borderless overlay window. It floats above normal windows on every Space.
- Window frames and their front-to-back order come from `CGWindowListCopyWindowInfo`, checked 10 times a second.
- Dock, desktop icon and widget frames come from the Accessibility API on a background queue.
- Every surface gets a pile: a height map of snow along its top edge, one column per 3 points. Columns hidden behind something in front aren't drawn and can't catch snow.
- Frames are driven by the display link. Piles are drawn into cached tiles that only redraw when their snow changes. Flakes, falling clumps and the elf are pre-rendered sprites.

## Debugging

Snowfall logs Accessibility and pause state changes:

```bash
log stream --predicate 'process == "Snowfall"'
```

At launch it also writes the Accessibility trees it reads to `~/Library/Logs/Snowfall-diagnostics.txt`. They're used to calibrate surface shapes.
