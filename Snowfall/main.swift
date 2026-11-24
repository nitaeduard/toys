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

import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

let bucketW: CGFloat = 3      // width of one height-map column, in points

let flakeColor = CGColor(srgbRed: 0.86, green: 0.93, blue: 1.00, alpha: 0.95)
let pileColor  = CGColor(srgbRed: 0.93, green: 0.96, blue: 1.00, alpha: 0.97)
let shadowColor = CGColor(srgbRed: 0.10, green: 0.20, blue: 0.40, alpha: 0.30)

// MARK: - Model

struct Flake {
    var p: CGPoint
    var vy, r, phase, sway, angle, spin: CGFloat
}

struct Clump {
    var p: CGPoint
    var v: CGVector
    var r: CGFloat
}

/// Something snow can settle on.
struct Surface {
    let key: String
    let rect: CGRect
    let radius: CGFloat   // corner radius
    let depth: CGFloat    // max snow depth on flat parts
    let maxDrape: CGFloat // how far overflowing snow may hang down over the front
    /// Optional exact top outline: per column, distance from rect.minY down to the
    /// first opaque pixel (nil = nothing there). Used for desktop icons.
    var profile: [CGFloat?]? = nil
}

final class Pile {
    let frame: CGRect
    var h: [CGFloat]            // snow depth per column
    let base: [CGFloat]         // how far the surface dips below frame.minY (rounded corners)
    let capH: [CGFloat]         // max depth per column: less on corners, lumpy elsewhere
    let solid: [Bool]           // false where the surface has no shape (transparent icon column)
    let flat: [Bool]            // gentle enough for overflow to hang down from
    var visible: [Bool]         // false where something in front covers this edge
    var drape: [CGFloat]        // overflow snow hanging down over the surface's front
    var drapeVisible: [Bool]
    var breakAt: [CGFloat]      // drape length at which a chunk breaks off
    let maxDrape: CGFloat

    init(_ s: Surface) {
        frame = s.rect
        let n = max(1, Int(s.rect.width / bucketW))
        let r = min(s.radius, s.rect.width / 2, s.rect.height / 2)
        let w = s.rect.width
        if let p = s.profile {
            let cols = (0..<n).map { $0 < p.count ? p[$0] : nil }
            base = cols.map { $0 ?? s.rect.height }
            solid = cols.map { $0 != nil }
        } else {
            base = (0..<n).map { i in
                let dx = min((CGFloat(i) + 0.5) * bucketW, w - (CGFloat(i) + 0.5) * bucketW)
                guard dx < r else { return 0 }
                return r - sqrt(max(0, r * r - (r - dx) * (r - dx)))   // circle arc
            }
            solid = Array(repeating: true, count: n)
        }
        let b = base
        let slope: [CGFloat] = (0..<n).map { i in
            let l = max(0, i - 1), rr = min(n - 1, i + 1)
            return abs(b[rr] - b[l]) / (bucketW * CGFloat(max(1, rr - l)))
        }
        let isSolid = solid
        flat = (0..<n).map { isSolid[$0] && slope[$0] < 0.35 }
        // Smooth noise so a full pile is lumpy instead of a flat, "cropped" line.
        let p1 = CGFloat.random(in: 0...100), p2 = CGFloat.random(in: 0...100)
        let hasProfile = s.profile != nil
        capH = b.enumerated().map { i, bi in
            guard isSolid[i] else { return 0 }
            let x = (CGFloat(i) + 0.5) * bucketW
            let noise = 0.5 + 0.25 * sin(x / 23 + p1) + 0.25 * sin(x / 9 + p2)
            let shape = hasProfile ? pow(max(0, 1 - slope[i]), 2)            // less on steep outline
                                   : (r > 0 ? pow(max(0, 1 - bi / r), 2) : 1) // rounded corners
            return s.depth * shape * (0.75 + 0.5 * noise)
        }
        h = Array(repeating: 0, count: n)
        visible = Array(repeating: true, count: n)
        drape = Array(repeating: 0, count: n)
        drapeVisible = Array(repeating: true, count: n)
        maxDrape = s.maxDrape
        breakAt = (0..<n).map { _ in Pile.randomBreak(s.maxDrape) }
    }

    static func randomBreak(_ maxDrape: CGFloat) -> CGFloat {
        maxDrape > 0 ? .random(in: (maxDrape * 0.45)...maxDrape) : 0
    }

    /// Keep the snow of `old` at the same screen positions (used when the Dock
    /// grows or shrinks sideways as apps open and quit).
    func transfer(from old: Pile) {
        for i in h.indices where solid[i] {
            let x = frame.minX + (CGFloat(i) + 0.5) * bucketW
            let j = Int(floor((x - old.frame.minX) / bucketW))
            guard j >= 0, j < old.h.count else { continue }
            h[i] = min(capH[i], old.h[j])
            if flat[i] { drape[i] = old.drape[j] }
        }
    }

    /// Y of the snow surface at column i (y grows downward).
    func top(_ i: Int) -> CGFloat { frame.minY + base[i] - h[i] }

    /// Add snow at column i. It slides toward lower neighbours, so it spills
    /// off the curved corners and piles up naturally in the middle. Once a
    /// column is full, the extra snow creeps down over the front edge.
    /// Returns the column where a chunk should break off, if any.
    func add(at i: Int, _ amount: CGFloat) -> Int? {
        var j = i
        for _ in 0..<10 {
            let l = j > 0 ? top(j - 1) : -.infinity
            let r = j < h.count - 1 ? top(j + 1) : -.infinity
            guard max(l, r) - top(j) > 1.2 else { break }
            j = l > r ? j - 1 : j + 1
        }
        if h[j] + amount <= capH[j] { h[j] += amount; return nil }
        h[j] = capH[j]
        guard maxDrape > 0, flat[j] else { return nil }   // on a corner it just slides off

        drape[j] += amount * 2.5
        // Share with neighbours so it hangs in soft lumps instead of spikes.
        for k in [j - 1, j + 1] where k >= 0 && k < h.count && flat[k] {
            let d = drape[j] - drape[k]
            if d > 2 { drape[k] += d * 0.35; drape[j] -= d * 0.2 }
        }
        return drape[j] > breakAt[j] ? j : nil
    }
}

final class World {
    var desktop = CGRect.zero
    var flakes: [Flake] = []
    var clumps: [Clump] = []
    var piles: [String: Pile] = [:]
    var order: [String] = []                       // surface keys, front-to-back
    var axSurfaces: (dock: [Surface], icons: [Surface]) = ([], [])
    /// Frames of the individual Dock items, to notice magnification.
    var dockItems: [CGRect] = []

    // Telling apart why a window disappeared.
    var windowPIDs: [String: Int] = [:]                  // window key → owning process
    var stashed: [String: Pile] = [:]                    // windows on another Space, restored on return
    var pending: [(key: String, pile: Pile, time: CFTimeInterval)] = []   // undecided: minimised or Space switch?
    var lastSpaceChange: CFTimeInterval = -100           // set from NSWorkspace notifications
    var recentlyHidden: [Int: CFTimeInterval] = [:]      // pid → time of Cmd+H
    private var refreshCount = 0
    /// Widget window frame → visible card frame, read via Accessibility.
    var widgetCards: [(window: CGRect, card: CGRect)] = []
    var flakeCount = 350
    private var t: CGFloat = 0
    private var wind: CGFloat = 0
    private var bundleIDs: [Int: String] = [:]

    func newFlake(anywhere: Bool) -> Flake {
        let r = CGFloat.random(in: 1...3.2)
        return Flake(
            p: CGPoint(x: .random(in: desktop.minX...desktop.maxX),
                       y: anywhere ? .random(in: desktop.minY...desktop.maxY) : desktop.minY - 5),
            vy: 25 + r * 18 + .random(in: 0...15),
            r: r,
            phase: .random(in: 0...(2 * .pi)),
            sway: .random(in: 8...25),
            angle: .random(in: 0...(.pi / 3)),
            spin: .random(in: -1.2...1.2))
    }

    private func bundleID(_ pid: Int) -> String {
        if let id = bundleIDs[pid] { return id }
        let id = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier ?? ""
        bundleIDs[pid] = id
        return id
    }

    // MARK: Surface tracking

    func refreshSurfaces() {
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return }
        let myPID = Int(getpid())

        var windows: [Surface] = [], widgets: [Surface] = []
        var pids: [String: Int] = [:]
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? Int, pid != myPID,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  rect.width > 40, rect.height > 40,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.1
            else { continue }
            pids["w\(id)"] = pid
            if layer == 0 {
                windows.append(Surface(key: "w\(id)", rect: rect, radius: 16, depth: 16, maxDrape: 36))
            } else if layer < 0, rect.width < 1000, bundleID(pid) == "com.apple.notificationcenterui" {
                // The widget window has transparent padding around the visible card.
                // Use the card frame from Accessibility; without it, the measured 8 pt inset.
                let card = widgetCards.first { $0.window == rect }?.card ?? rect.insetBy(dx: 8, dy: 8)
                widgets.append(Surface(key: "w\(id)", rect: card, radius: 22, depth: 12, maxDrape: 20))
            }
        }

        // Front-to-back: Dock, app windows, widgets, desktop icons.
        let surfaces = axSurfaces.dock + windows + widgets + axSurfaces.icons

        let now = CACurrentMediaTime()
        var newPiles: [String: Pile] = [:]
        for s in surfaces {
            if let pile = piles[s.key], pile.frame == s.rect {
                newPiles[s.key] = pile
            } else if piles[s.key] == nil, let pile = stashed[s.key] ?? pending.first(where: { $0.key == s.key })?.pile {
                // Back from another Space (or a brief flicker): same place → same snow.
                stashed[s.key] = nil
                pending.removeAll { $0.key == s.key }
                newPiles[s.key] = pile.frame == s.rect ? pile : Pile(s)
            } else if let old = piles[s.key], s.key.hasPrefix("dock"),
                      abs(old.frame.maxY - s.rect.maxY) < 30,
                      old.frame.minX < s.rect.maxX, s.rect.minX < old.frame.maxX {
                // Dock resized in place (apps opening/quitting, magnification): the snow
                // stays where it is. Moving to another screen or hiding drops it all.
                let pile = Pile(s)
                pile.transfer(from: old)
                newPiles[s.key] = pile
            } else {
                if let old = piles[s.key] { shakeOff(old) }   // moved or resized → snow falls
                newPiles[s.key] = Pile(s)
            }
        }
        handleVanished(piles.keys.filter { newPiles[$0] == nil && $0.hasPrefix("w") }, now: now)
        piles = newPiles
        windowPIDs.merge(pids) { _, new in new }
        order = surfaces.map(\.key)

        // Hide snow columns covered by something further in front.
        for (i, s) in surfaces.enumerated() {
            guard let pile = piles[s.key] else { continue }
            let front = surfaces[..<i].map(\.rect)
            for b in pile.h.indices {
                let p = CGPoint(x: s.rect.minX + (CGFloat(b) + 0.5) * bucketW, y: pile.top(b) - 1)
                pile.visible[b] = !front.contains { $0.contains(p) }
                let edge = s.rect.minY + pile.base[b]
                let q1 = CGPoint(x: p.x, y: edge + 1), q2 = CGPoint(x: p.x, y: edge + max(pile.drape[b], 1))
                pile.drapeVisible[b] = !front.contains { $0.contains(q1) || $0.contains(q2) }
            }
        }
    }

    /// Why did these windows disappear?
    ///  - closed (gone from the full window list) or app hidden (Cmd+H): snow falls now
    ///  - otherwise minimised or on another Space; decided a moment later, because the
    ///    Space-change notification can arrive just after the window list changes:
    ///    Space switch → keep the snow for when it returns, minimised → snow falls.
    private func handleVanished(_ keys: [String], now: CFTimeInterval) {
        refreshCount += 1
        if !keys.isEmpty || (refreshCount % 50 == 0 && !stashed.isEmpty) {
            let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
            let existing = Set(all.compactMap { $0[kCGWindowNumber as String] as? Int })
            func exists(_ key: String) -> Bool { Int(key.dropFirst()).map(existing.contains) ?? false }

            for key in keys {
                guard let pile = piles[key] else { continue }
                let pid = windowPIDs[key] ?? -1
                let hidden = NSRunningApplication(processIdentifier: pid_t(pid))?.isHidden == true
                    || now - (recentlyHidden[pid] ?? -100) < 2
                if !exists(key) || hidden {
                    shakeOff(pile)
                } else {
                    pending.append((key, pile, now))
                }
            }
            // Forget snow of windows closed while on another Space.
            stashed = stashed.filter { exists($0.key) }
            windowPIDs = windowPIDs.filter { exists($0.key) }
        }

        pending.removeAll { p in
            guard now - p.time > 0.4 else { return false }
            if abs(lastSpaceChange - p.time) < 1.5 {
                stashed[p.key] = p.pile
            } else {
                shakeOff(p.pile)
            }
            return true
        }
    }

    func shakeOff(_ pile: Pile, columns: Range<Int>? = nil) {
        let cols = columns ?? pile.h.indices
        for b in cols {
            let h = pile.h[b]
            guard (h > 0.4 && pile.visible[b]) || pile.drape[b] > 0.5 else { continue }
            let x0 = pile.frame.minX + CGFloat(b) * bucketW
            let bottom = pile.frame.minY + pile.base[b] + (pile.drapeVisible[b] ? pile.drape[b] : 0)
            var remaining = (pile.visible[b] ? h : 0) + (pile.drapeVisible[b] ? pile.drape[b] : 0)
            while remaining > 0 {
                let r = CGFloat.random(in: 1.2...2.6)
                clumps.append(Clump(
                    p: CGPoint(x: x0 + .random(in: 0...bucketW), y: bottom - remaining),
                    v: CGVector(dx: .random(in: -25...25), dy: .random(in: -40...10)),
                    r: r))
                remaining -= r * 1.6
            }
            if columns != nil { pile.h[b] = 0; pile.drape[b] = 0 }
        }
        if clumps.count > 8000 { clumps.removeFirst(clumps.count - 8000) }
    }

    /// Overhanging snow got too heavy: a chunk around column j falls off,
    /// taking part of the pile above it along.
    func breakChunk(_ pile: Pile, at j: Int) {
        let n = pile.h.count
        var lo = j, hi = j
        while lo > 0, pile.drape[lo - 1] > 1.5, j - lo < 8 { lo -= 1 }
        while hi < n - 1, pile.drape[hi + 1] > 1.5, hi - j < 8 { hi += 1 }
        for b in lo...hi {
            let lost = pile.h[b] * .random(in: 0.25...0.5)
            if pile.drapeVisible[b] {
                let edge = pile.frame.minY + pile.base[b]
                var y = edge + pile.drape[b]
                while y > edge - lost {
                    let r = CGFloat.random(in: 1.5...3.2)
                    clumps.append(Clump(
                        p: CGPoint(x: pile.frame.minX + (CGFloat(b) + .random(in: 0...1)) * bucketW, y: y),
                        v: CGVector(dx: .random(in: -12...12), dy: .random(in: 0...30)),
                        r: r))
                    y -= r * 1.5
                }
            }
            pile.h[b] -= lost
            pile.drape[b] = 0
            pile.breakAt[b] = Pile.randomBreak(pile.maxDrape)
        }
    }

    func clearSnow() {
        for pile in piles.values {
            pile.h = pile.h.map { _ in 0 }
            pile.drape = pile.drape.map { _ in 0 }
        }
        clumps.removeAll()
    }

    /// Dock magnification: an item that grows or shrinks knocks the snow off
    /// the part of the Dock it covers. Adding/removing apps only shifts items.
    func updateDockItems(_ items: [CGRect]) {
        defer { dockItems = items }
        guard items.count == dockItems.count else { return }
        for (old, new) in zip(dockItems, items)
        where abs(old.width - new.width) > 1 || abs(old.height - new.height) > 1 {
            let lo = min(old.minX, new.minX), hi = max(old.maxX, new.maxX)
            for s in axSurfaces.dock {
                guard let pile = piles[s.key] else { continue }
                let a = max(0, Int((lo - pile.frame.minX) / bucketW))
                let b = min(pile.h.count, Int(ceil((hi - pile.frame.minX) / bucketW)))
                if a < b { shakeOff(pile, columns: a..<b) }
            }
        }
    }

    /// Drop the snow from Dock and desktop icons (used when that feature is turned off).
    func shakeOffAXSurfaces() {
        for s in axSurfaces.dock + axSurfaces.icons { if let p = piles[s.key] { shakeOff(p) } }
        axSurfaces = ([], [])
        dockItems = []
    }

    // MARK: Simulation

    /// Returns true if the flake was absorbed by a snow pile.
    private func land(_ f: Flake, prevY: CGFloat) -> Bool {
        for key in order {     // front-to-back: first hit wins (handles overlap)
            guard let pile = piles[key] else { continue }
            let rect = pile.frame
            guard f.p.x >= rect.minX, f.p.x < rect.maxX else { continue }
            let b = min(pile.h.count - 1, Int((f.p.x - rect.minX) / bucketW))
            guard pile.solid[b] else { continue }   // transparent part of an icon
            let surface = pile.top(b)
            guard f.p.y >= surface, f.p.y <= rect.maxY else { continue }
            // The flake is inside this surface's region. Did it just cross the top?
            if prevY <= surface + 1 {
                if let j = pile.add(at: b, f.r * 0.35) { breakChunk(pile, at: j) }
                return true
            }
            return false   // drifting in front of it
        }
        return false
    }

    func update(dt: CGFloat) {
        t += dt
        wind = sin(t * 0.13) * 12 + sin(t * 0.37) * 5

        if flakes.isEmpty { flakes = (0..<flakeCount).map { _ in newFlake(anywhere: true) } }

        for i in flakes.indices {
            var f = flakes[i]
            let prevY = f.p.y
            f.phase += dt * 1.3
            f.angle += f.spin * dt
            f.p.y += f.vy * dt
            f.p.x += (sin(f.phase) * f.sway + wind) * dt
            if f.p.x < desktop.minX - 20 { f.p.x = desktop.maxX }
            if f.p.x > desktop.maxX + 20 { f.p.x = desktop.minX }

            if land(f, prevY: prevY) || f.p.y > desktop.maxY + 5 {
                f = newFlake(anywhere: false)
            }
            flakes[i] = f
        }

        for i in clumps.indices {
            clumps[i].v.dy += 900 * dt
            clumps[i].p.x += clumps[i].v.dx * dt
            clumps[i].p.y += clumps[i].v.dy * dt
        }
        clumps.removeAll { $0.p.y > desktop.maxY + 10 }
    }
}

// MARK: - Accessibility (Dock + desktop icons)

enum AXScanner {
    private static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private static func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "" }
    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return s.width > 0 && s.height > 0 ? CGRect(origin: p, size: s) : nil
    }
    private static func app(_ bundleID: String) -> AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    /// Writes the Accessibility trees of the widget host, Dock and Finder desktop
    /// to ~/Library/Logs/Snowfall-diagnostics.txt (to calibrate surface shapes).
    static func writeDiagnostics(widgetWindows: [CGRect]) {
        var out = "trusted=\(AXIsProcessTrusted())\nwidget windows: \(widgetWindows)\n"
        func dump(_ e: AXUIElement, _ d: Int) {
            guard d < 9 else { return }
            let title = attr(e, kAXTitleAttribute) as? String ?? ""
            let sub = attr(e, kAXSubroleAttribute) as? String ?? ""
            let desc = attr(e, kAXDescriptionAttribute) as? String ?? ""
            out += String(repeating: "  ", count: d) + "\(role(e)) \(sub) '\(title)' '\(desc)' \(frame(e).map { "\($0)" } ?? "-")\n"
            for c in children(e).prefix(12) { dump(c, d + 1) }
        }
        // Attributes of the first desktop icon, to see what identifies its file.
        if let f = app("com.apple.finder"),
           let area = children(f).first(where: { role($0) == kAXScrollAreaRole }),
           let group = children(area).first,
           let icon = children(group).first(where: { role($0) == kAXImageRole }) {
            var names: CFArray?
            AXUIElementCopyAttributeNames(icon, &names)
            for n in (names as? [String]) ?? [] { out += "icon attr \(n) = \(String(describing: attr(icon, n)).prefix(160))\n" }
        }
        for id in ["com.apple.notificationcenterui", "com.apple.dock", "com.apple.finder"] {
            out += "== \(id)\n"
            if let a = app(id) { dump(a, 0) }
        }
        out += "== icon outlines (pt from top of 64pt box, per 3pt column)\n" + IconShapes.describe() + "\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Snowfall-diagnostics.txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Each desktop widget is an AXWindow (with padding) containing an AXGroup for the card.
    static func widgetCards() -> [(window: CGRect, card: CGRect)] {
        guard AXIsProcessTrusted(), let nc = app("com.apple.notificationcenterui") else { return [] }
        var out: [(window: CGRect, card: CGRect)] = []
        for w in children(nc) where role(w) == kAXWindowRole {
            guard let wf = frame(w) else { continue }
            func find(_ e: AXUIElement, depth: Int) -> CGRect? {
                for c in children(e) {
                    if role(c) == kAXGroupRole, let f = frame(c), f.width < wf.width - 1, wf.contains(f) { return f }
                    if depth < 3, let f = find(c, depth: depth + 1) { return f }
                }
                return nil
            }
            if let card = find(w, depth: 0) { out.append((wf, card)) }
        }
        return out
    }

    /// The Dock's platter (its AXList) and the frames of its items.
    static func scanDock(enabled: Bool) -> (surfaces: [Surface], items: [CGRect]) {
        guard enabled, AXIsProcessTrusted(), let d = app("com.apple.dock") else { return ([], []) }
        var dock: [Surface] = [], items: [CGRect] = []
        for (i, list) in children(d).enumerated() where role(list) == kAXListRole {
            guard let f = frame(list) else { continue }
            dock.append(Surface(key: "dock\(i)", rect: f, radius: min(f.height * 0.4, 26), depth: 12, maxDrape: 10))
            items += children(list).compactMap(frame)
        }
        return (dock, items)
    }

    static func scanIcons(enabled: Bool) -> [Surface] {
        guard enabled, AXIsProcessTrusted() else { return [] }
        var icons: [Surface] = []
        if let finder = app("com.apple.finder") {
            // The desktop is an AXScrollArea directly under Finder; icons are AXImages inside it.
            var seen = Set<String>(), seenFrames = Set<String>()
            let preview = IconShapes.finderShowsPreviews
            func collect(_ e: AXUIElement, depth: Int) {
                for c in children(e) {
                    if role(c) == kAXImageRole, let f = frame(c) {
                        guard seenFrames.insert("\(f)").inserted else { continue }   // Finder lists some twice
                        let name = attr(c, kAXTitleAttribute) as? String ?? "\(f.origin)"
                        var key = "icon:" + name
                        while seen.contains(key) { key += "'" }
                        seen.insert(key)
                        // Snow follows the real outline of the icon (or thumbnail) Finder draws.
                        let url = (attr(c, "AXURL") as? NSURL)?.filePathURL
                        let profile = IconShapes.profile(url: url, name: name, size: f.size, preview: preview)
                        icons.append(Surface(key: key, rect: f, radius: 0, depth: 7, maxDrape: 6, profile: profile))
                    } else if depth < 3 {
                        collect(c, depth: depth + 1)
                    }
                }
            }
            for c in children(finder) where role(c) == kAXScrollAreaRole { collect(c, depth: 0) }
        }
        return icons
    }
}

// MARK: - Icon outlines

/// Renders the icon Finder shows for a desktop item and measures its top edge.
/// Only used from the serial Accessibility queue.
enum IconShapes {
    private static var cache: [String: [CGFloat?]] = [:]
    private static var lastError = ""

    static var finderShowsPreviews: Bool {
        let v = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any]
        return (v?["IconViewSettings"] as? [String: Any])?["showIconPreview"] as? Bool ?? true
    }

    static func describe() -> String {
        "last thumbnail error: \(lastError)\nreadable desktop: \(FileManager.default.isReadableFile(atPath: NSHomeDirectory() + "/Desktop"))\n" + cache.map { k, v in
            "\((k as NSString).lastPathComponent): " + v.map { $0.map { String(Int($0)) } ?? "-" }.joined(separator: " ")
        }.sorted().joined(separator: "\n")
    }

    static func profile(url: URL?, name: String, size: CGSize, preview: Bool) -> [CGFloat?] {
        let key = "\(url?.path ?? name)|\(size.width)x\(size.height)|\(preview)"
        if let p = cache[key] { return p }
        let p = image(url: url, name: name, size: size, preview: preview).map { outline(of: $0, box: size) }
            ?? Array(repeating: 0, count: max(1, Int(size.width / bucketW)))
        cache[key] = p
        return p
    }

    private static func image(url: URL?, name: String, size: CGSize, preview: Bool) -> CGImage? {
        // Content preview (what Finder shows with "Show icon preview"), e.g. for screenshots.
        // Quick Look picks the best of thumbnail / plain icon for each file.
        if let url, preview {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .all)
            let done = DispatchSemaphore(value: 0)
            var result: CGImage?
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, err in
                if let err { lastError = "\(url.path): \(err)" }
                result = rep?.cgImage
                done.signal()
            }
            if done.wait(timeout: .now() + 3) == .success, let result { return result }
        }
        // Plain file icon; without a file, the icon for its type.
        let icon: NSImage
        if let url {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            let ext = (name as NSString).pathExtension
            icon = NSWorkspace.shared.icon(for: ext.isEmpty ? .folder : (UTType(filenameExtension: ext) ?? .data))
        }
        var rect = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)
        return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Per column (bucketW wide): points from the top of the box to the first mostly
    /// opaque pixel, with the image aspect-fit and centred like Finder draws it.
    private static func outline(of image: CGImage, box: CGSize) -> [CGFloat?] {
        let scale: CGFloat = 2
        let W = max(1, Int(box.width * scale)), H = max(1, Int(box.height * scale))
        let n = max(1, Int(box.width / bucketW))
        var px = [UInt8](repeating: 0, count: W * H * 4)
        return px.withUnsafeMutableBytes { buf -> [CGFloat?] in
            guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8,
                                      bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return Array(repeating: 0, count: n) }
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let s = min(CGFloat(W) / iw, CGFloat(H) / ih)
            ctx.draw(image, in: CGRect(x: (CGFloat(W) - iw * s) / 2, y: (CGFloat(H) - ih * s) / 2,
                                       width: iw * s, height: ih * s))
            // Bitmap memory starts at the top row.
            return (0..<n).map { i in
                let x0 = Int(CGFloat(i) * bucketW * scale), x1 = min(W, Int(CGFloat(i + 1) * bucketW * scale))
                for y in 0..<H {
                    for x in x0..<x1 where buf[(y * W + x) * 4 + 3] > 140 { return CGFloat(y) / scale }
                }
                return nil
            }
        }
    }
}

// MARK: - Rendering

final class SnowView: NSView {
    let world: World
    let origin: CGPoint   // this screen's top-left in global top-left coords

    init(world: World, frame: NSRect, origin: CGPoint) {
        self.world = world
        self.origin = origin
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// For each run of included columns, adds a closed shape whose outer edge is a
    /// smooth curve through `outer` points and whose inner edge follows `inner`.
    private func addRuns(_ path: CGMutablePath, count n: Int, include: (Int) -> Bool,
                         outer: (Int) -> CGPoint, inner: (Int) -> CGPoint) {
        var b = 0
        while b < n {
            guard include(b) else { b += 1; continue }
            let start = b
            while b < n, include(b) { b += 1 }
            let pts = (start..<b).map(outer)
            let startInner = inner(start), endInner = inner(b - 1)
            path.move(to: CGPoint(x: startInner.x - bucketW / 2, y: startInner.y))
            path.addLine(to: pts[0])
            for k in 1..<pts.count {   // quadratic curves through midpoints = smooth outline
                let mid = CGPoint(x: (pts[k - 1].x + pts[k].x) / 2, y: (pts[k - 1].y + pts[k].y) / 2)
                path.addQuadCurve(to: mid, control: pts[k - 1])
            }
            path.addLine(to: pts[pts.count - 1])
            path.addLine(to: CGPoint(x: endInner.x + bucketW / 2, y: endInner.y))
            for k in stride(from: b - 1, through: start, by: -1) { path.addLine(to: inner(k)) }
            path.closeSubpath()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.translateBy(x: -origin.x, y: -origin.y)
        let area = CGRect(origin: origin, size: bounds.size).insetBy(dx: -10, dy: -30)

        // Soft bluish shadow so snow is visible on white windows too.
        ctx.setShadow(offset: .zero, blur: 2.5, color: shadowColor)

        // Piles (above the edge) and drapes (overflow hanging over the front):
        // one smooth blob per contiguous run of columns, hugging the rounded corners.
        let piles = CGMutablePath()
        for key in world.order {
            guard let pile = world.piles[key], pile.frame.intersects(area) else { continue }
            let x0 = pile.frame.minX, y0 = pile.frame.minY
            func cx(_ k: Int) -> CGFloat { x0 + (CGFloat(k) + 0.5) * bucketW }
            // Above the edge: outer = snow surface, inner = window edge.
            addRuns(piles, count: pile.h.count, include: { pile.visible[$0] && pile.h[$0] > 0.3 },
                    outer: { CGPoint(x: cx($0), y: pile.top($0)) },
                    inner: { CGPoint(x: cx($0), y: y0 + pile.base[$0] + 0.5) })
            // Below the edge: outer = hanging tip, inner = window edge.
            addRuns(piles, count: pile.h.count, include: { pile.drapeVisible[$0] && pile.drape[$0] > 0.5 },
                    outer: { CGPoint(x: cx($0), y: y0 + pile.base[$0] + pile.drape[$0]) },
                    inner: { CGPoint(x: cx($0), y: y0 + pile.base[$0] - 0.5) })
        }
        ctx.setFillColor(pileColor)
        ctx.addPath(piles)
        ctx.fillPath()

        // Falling clumps: little round lumps.
        let lumps = CGMutablePath()
        for c in world.clumps where area.contains(c.p) {
            lumps.addEllipse(in: CGRect(x: c.p.x - c.r, y: c.p.y - c.r, width: c.r * 2, height: c.r * 2))
        }
        ctx.addPath(lumps)
        ctx.fillPath()

        // Flakes: six arms; bigger flakes also get little V-branches.
        let flakes = CGMutablePath()
        for f in world.flakes where area.contains(f.p) {
            let len = f.r * 1.5
            for k in 0..<6 {
                let a = f.angle + CGFloat(k) * .pi / 3
                let dir = CGPoint(x: cos(a), y: sin(a))
                flakes.move(to: f.p)
                flakes.addLine(to: CGPoint(x: f.p.x + dir.x * len, y: f.p.y + dir.y * len))
                if f.r > 2 {
                    let b = CGPoint(x: f.p.x + dir.x * len * 0.55, y: f.p.y + dir.y * len * 0.55)
                    for side in [-1.0, 1.0] as [CGFloat] {
                        let ba = a + side * .pi / 4
                        flakes.move(to: b)
                        flakes.addLine(to: CGPoint(x: b.x + cos(ba) * len * 0.38, y: b.y + sin(ba) * len * 0.38))
                    }
                }
            }
        }
        ctx.setStrokeColor(flakeColor)
        ctx.setLineWidth(0.9)
        ctx.setLineCap(.round)
        ctx.addPath(flakes)
        ctx.strokePath()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let world = World()
    var overlays: [NSWindow] = []
    var statusItem: NSStatusItem!
    var axItem: NSMenuItem!
    var lastTick = CACurrentMediaTime()
    let axQueue = DispatchQueue(label: "snowfall.ax", qos: .utility)
    var lastAXLog = ""
    var axBusy = false
    var axTick = 0
    
    /// User's choice for Dock & desktop-icon snow (only takes effect once permission is granted).
    var axEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "dockIconSnow") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dockIconSnow") }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildOverlays()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let widgets = self.world.order.compactMap { self.world.piles[$0] }.map(\.frame)
            self.axQueue.async { AXScanner.writeDiagnostics(widgetWindows: widgets) }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(buildOverlays),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.world.recentlyHidden[Int(app.processIdentifier)] = CACurrentMediaTime()
            }
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.world.lastSpaceChange = CACurrentMediaTime()
        }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "❄︎"
        let menu = NSMenu()
        menu.delegate = self
        let clear = NSMenuItem(title: "Clear Snow", action: #selector(clearSnow), keyEquivalent: "")
        clear.target = self
        axItem = NSMenuItem(title: "Snow on Dock & Desktop Icons", action: #selector(toggleAX), keyEquivalent: "")
        axItem.target = self
        menu.addItem(clear)
        menu.addItem(axItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Snowfall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        
        // Ask for Accessibility once; afterwards it's available from the menu.
        if !AXIsProcessTrusted() && !UserDefaults.standard.bool(forKey: "askedAX") {
            UserDefaults.standard.set(true, forKey: "askedAX")
            requestAX()
        }
        
        world.refreshSurfaces()
        let poll = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.world.refreshSurfaces() }
        let frame = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        let ax = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.scanAX() }
        for t in [poll, frame, ax] { RunLoop.main.add(t, forMode: .common) }
    }
    
    /// Dock every tick (10x/s, so magnification reacts quickly); desktop icons and
    /// widget cards every 5th tick. Skips a tick if the previous scan is still running.
    func scanAX() {
        guard !axBusy else { return }
        axBusy = true
        axTick += 1
        let enabled = axEnabled, full = axTick % 5 == 1
        axQueue.async { [weak self] in
            let dock = AXScanner.scanDock(enabled: enabled)
            let icons = full ? AXScanner.scanIcons(enabled: enabled) : nil
            let cards = full ? AXScanner.widgetCards() : nil   // shape refinement only, not gated by the switch
            DispatchQueue.main.async {
                guard let self else { return }
                self.axBusy = false
                if let cards { self.world.widgetCards = cards }
                guard self.axEnabled == enabled else { return }   // toggled meanwhile
                self.world.updateDockItems(dock.items)
                self.world.axSurfaces = (dock.surfaces, icons ?? self.world.axSurfaces.icons)
                let result = self.world.axSurfaces
                // Log changes: `log stream --predicate 'process == "Snowfall"'`
                let msg = "AX enabled=\(enabled) trusted=\(AXIsProcessTrusted()) dock=\(result.dock.count) icons=\(result.icons.count)"
                if msg != self.lastAXLog { NSLog("%@", msg); self.lastAXLog = msg }
            }
        }
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        axItem.state = axEnabled && trusted ? .on : .off
        axItem.title = trusted ? "Snow on Dock & Desktop Icons"
        : "Snow on Dock & Desktop Icons (needs Accessibility)…"
    }
    
    /// With permission: a plain on/off switch. Without: ask for permission.
    @objc func toggleAX() {
        if AXIsProcessTrusted() {
            axEnabled.toggle()
            if !axEnabled { world.shakeOffAXSurfaces() }
        } else {
            axEnabled = true
            requestAX()
        }
    }
    
    func requestAX() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
    
    @objc func buildOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        guard let primary = NSScreen.screens.first?.frame else { return }
        
        var desktop = CGRect.null
        for screen in NSScreen.screens {
            let f = screen.frame
            // Convert AppKit (bottom-left) to global top-left coords.
            let origin = CGPoint(x: f.minX, y: primary.maxY - f.maxY)
            desktop = desktop.union(CGRect(origin: origin, size: f.size))
            
            let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(f, display: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.contentView = SnowView(world: world, frame: NSRect(origin: .zero, size: f.size), origin: origin)
            w.orderFrontRegardless()
            overlays.append(w)
        }
        world.desktop = desktop
    }
    
    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        world.update(dt: CGFloat(dt))
        for w in overlays { w.contentView?.needsDisplay = true }
    }
    
    @objc func clearSnow() { world.clearSnow() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
