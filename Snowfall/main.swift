// Snowfall — snow that falls over every window, piles up on window tops,
// desktop widgets, the Dock and desktop icons, and falls off when they move.
//
// How it works:
//  * One transparent, click-through, borderless overlay window per screen,
//    floating above normal windows on every Space.
//  * CGWindowListCopyWindowInfo (polled 10x/s) gives the frame and z-order of
//    app windows and desktop widgets. Reading bounds needs no permission.
//  * The Dock and desktop icons are not windows; their frames come from the
//    Accessibility API (needs the Accessibility permission, polled 2x/s).
//  * Each surface gets a "pile": a height map of snow along its top edge that
//    follows the rounded corners. When a surface moves, its pile falls off.
//
// All simulation coordinates are global, top-left origin (same as CGWindowList and AX).
//
// Files: SnowfallModel/Pile.swift (surfaces + snow piles, shared with the tests),
// World.swift (simulation + surface tracking), AXScanner.swift and IconShapes.swift
// (Accessibility), SnowView.swift (drawing), AppDelegate.swift (menu-bar app).

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
