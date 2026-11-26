import AppKit

/// The whole simulation: falling flakes, falling clumps and the piles on every surface.
@MainActor
final class World {
    var desktop = CGRect.zero
    var flakes: [Flake] = []
    var clumps: [Clump] = []
    var piles: [String: Pile] = [:]
    var order: [String] = []                       // surface keys, front-to-back
    /// The piles in `order`, so the per-flake loops don't hash keys every frame.
    private var stack: [(key: String, pile: Pile, isWindow: Bool)] = []
    /// For each 64 pt wide strip of the desktop, the `stack` indices (front-to-back)
    /// of the piles overlapping it, so a flake only checks the surfaces it is over.
    private var strips: [[Int]] = []
    private static let stripWidth: CGFloat = 64

    private func stripIndices(at x: CGFloat) -> [Int] {
        let i = Int((x - desktop.minX) / World.stripWidth)
        return i >= 0 && i < strips.count ? strips[i] : []
    }
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

    /// Screen frames, global top-left coords. Each screen with nothing below it gets
    /// a "ground" pile along its bottom edge that catches falling snow.
    var screens: [CGRect] = []
    /// Elves shovelling the ground snow away, walking along the bottom of a screen.
    var elves: [Elf] = []
    private var lastElfDir: [String: CGFloat] = [:]
    private var elfCheck: CGFloat = 0
    /// Time since piles last aged (they freeze every couple of seconds, not every frame).
    private var freezeClock: CGFloat = 0

    /// The frontmost app window, to notice when another one comes to the front.
    private var frontWindow: String?
    private var focusChange: (key: String, time: CFTimeInterval)?

    static let groundDepth: CGFloat = 56
    /// The elf comes when a screen's ground snow is deeper than half the Dock's
    /// height somewhere, or covers more than this fraction of the screen's width.
    static let elfWidthThreshold: CGFloat = 0.7
    /// Dock height to use when it isn't known (Dock snow off, or another screen).
    static let defaultDockHeight: CGFloat = 64
    /// Seconds for one pass across a screen, whatever its width.
    static let elfPassTime: CGFloat = 10
    /// How far in front of the elf's feet the shovel blade is.
    static let elfReach: CGFloat = 22

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

        // Front-to-back: Dock, app windows, widgets, desktop icons, the ground.
        let surfaces = axSurfaces.dock + windows + widgets + axSurfaces.icons + groundSurfaces()

        let now = CACurrentMediaTime()
        noticeFocusChange(front: windows.first?.key, now: now)
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
                if let old = piles[s.key] { shakeOff(old, key: s.key) }   // moved or resized → snow falls
                newPiles[s.key] = Pile(s)
            }
        }
        handleVanished(piles.keys.filter { newPiles[$0] == nil && $0.hasPrefix("w") }, now: now)
        piles = newPiles
        windowPIDs.merge(pids) { _, new in new }
        order = surfaces.map(\.key)
        stack = order.compactMap { key in piles[key].map { (key, $0, key.hasPrefix("w")) } }
        let stripCount = max(1, Int(ceil(desktop.width / World.stripWidth)))
        strips = Array(repeating: [], count: stripCount)
        for (i, item) in stack.enumerated() {
            let a = max(0, Int((item.pile.frame.minX - desktop.minX) / World.stripWidth))
            let b = min(stripCount - 1, Int((item.pile.frame.maxX - desktop.minX) / World.stripWidth))
            if a <= b { for k in a...b { strips[k].append(i) } }
        }
        shakeFocusedWindow(now: now)

        // Hide snow columns covered by something further in front.
        // Pile.updateVisibility only tests the front rects that overlap the pile and
        // skips the work when they and the snow are unchanged since last time.
        let rects = surfaces.map(\.rect)
        for (i, s) in surfaces.enumerated() {
            if s.key.hasPrefix("ground") {
                // Anything reaching down near the bottom (the Dock floats a few points
                // above it, windows may end just short) hides the ground behind it.
                let bottom = s.rect.minY
                let front = rects[..<i].map { r in
                    r.maxY > bottom - 24 && r.minY < bottom
                        ? CGRect(x: r.minX, y: r.minY, width: r.width, height: bottom + 1 - r.minY) : r
                }
                piles[s.key]?.updateVisibility(front: front[...])
            } else {
                piles[s.key]?.updateVisibility(front: rects[..<i])
            }
        }
    }

    /// A ground surface along the bottom of each screen that has no screen below it.
    /// Its rect reaches below the screen so snow crossing the edge is still caught.
    private func groundSurfaces() -> [Surface] {
        screens.enumerated().compactMap { i, s in
            let below = CGRect(x: s.minX, y: s.maxY, width: s.width, height: 2)
            guard !screens.contains(where: { $0 != s && $0.intersects(below) }) else { return nil }
            return Surface(key: "ground\(i)", rect: CGRect(x: s.minX, y: s.maxY, width: s.width, height: 40),
                           radius: 0, depth: World.groundDepth, maxDrape: 0)
        }
    }

    // MARK: Focus

    /// Another existing window came to the front. Decided a moment later, because a
    /// Space switch also changes the front window and its notification can arrive late.
    private func noticeFocusChange(front: String?, now: CFTimeInterval) {
        defer { frontWindow = front }
        guard let front, let previous = frontWindow, front != previous, piles[front] != nil else { return }
        focusChange = (front, now)
    }

    /// The window that got focus shakes its snow off, which then tumbles onto what's below.
    private func shakeFocusedWindow(now: CFTimeInterval) {
        guard let change = focusChange, now - change.time > 0.35 else { return }
        focusChange = nil
        guard change.key == frontWindow, abs(lastSpaceChange - change.time) > 1.5,
              let pile = piles[change.key] else { return }
        shakeOff(pile, key: change.key, columns: pile.h.indices)
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
                    shakeOff(pile, key: key)
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
                shakeOff(p.pile, key: p.key)
            }
            return true
        }
    }

    /// Knocks the snow off a pile as falling clumps. Snow from the Dock and the ground
    /// falls off the screen; other snow can land on whatever is below.
    func shakeOff(_ pile: Pile, key: String, columns: Range<Int>? = nil) {
        let cols = columns ?? pile.h.indices
        let lands = !key.hasPrefix("dock") && !key.hasPrefix("ground")
        // The whole top shaken (moved, closed, focused): the icicles break off too.
        if cols.count == pile.h.count { dropIcicles(pile, key: key) }
        for b in cols {
            let h = pile.h[b]
            guard (h > 0.4 && pile.visible[b]) || pile.drape[b] > 0.5 else { continue }
            let x0 = pile.frame.minX + CGFloat(b) * bucketW
            let edge = pile.frame.minY + pile.base[b]
            let bottom = edge + (pile.drapeVisible[b] ? pile.drape[b] : 0)
            // The icy bottom of the pile comes off as shards, which don't stick anywhere.
            let iceTop = edge - (pile.visible[b] ? pile.iceDepth(b) : 0)
            var remaining = (pile.visible[b] ? h : 0) + (pile.drapeVisible[b] ? pile.drape[b] : 0)
            while remaining > 0 {
                let y = bottom - remaining
                let isIce = y >= iceTop && y <= edge && iceTop < edge
                let r = isIce ? CGFloat.random(in: 1.0...2.2) : CGFloat.random(in: 1.2...2.6)
                clumps.append(Clump(
                    p: CGPoint(x: x0 + .random(in: 0...bucketW), y: y),
                    v: CGVector(dx: .random(in: -25...25), dy: .random(in: -40...10)),
                    r: r, from: key, lands: lands && !isIce, ice: isIce))
                remaining -= clumpSnow(r)
            }
            if columns != nil { pile.h[b] = 0; pile.drape[b] = 0; pile.ice[b] = 0 }
        }
        if clumps.count > 8000 { clumps.removeFirst(clumps.count - 8000) }
    }

    /// Icicles snap off and fall as shards.
    private func dropIcicles(_ pile: Pile, key: String) {
        for ic in pile.icicles() where pile.drapeVisible[ic.column] {
            var y = ic.top
            while y < ic.top + ic.length {
                let along = (y - ic.top) / ic.length          // icicles taper to a point
                clumps.append(Clump(
                    p: CGPoint(x: ic.x + .random(in: -0.5...0.5), y: y),
                    v: CGVector(dx: .random(in: -10...10), dy: .random(in: 0...40)),
                    r: max(0.8, ic.width / 2 * (1 - along)), from: key, lands: false, ice: true))
                y += 3
            }
        }
        pile.clearIcicles()
    }

    /// Overhanging snow got too heavy: a chunk around column j falls off,
    /// taking part of the pile above it along.
    func breakChunk(_ pile: Pile, key: String, at j: Int) {
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
                        r: r, from: key, lands: !key.hasPrefix("dock") && !key.hasPrefix("ground")))
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
            pile.ice = pile.ice.map { _ in 0 }
            pile.clearIcicles()
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
                if a < b { shakeOff(pile, key: s.key, columns: a..<b) }
            }
        }
    }

    /// Drop the snow from Dock and desktop icons (used when that feature is turned off).
    func shakeOffAXSurfaces() {
        for s in axSurfaces.dock + axSurfaces.icons { if let p = piles[s.key] { shakeOff(p, key: s.key) } }
        axSurfaces = ([], [])
        dockItems = []
    }

    // MARK: Simulation

    private enum FlakeHit { case none, landed, side(x: CGFloat) }

    /// What happened to a flake that moved from `prev`: it landed on a pile, hit
    /// the side of a window (it melts there, and the water feeds that corner's
    /// icicles), or is still falling.
    private func land(_ f: Flake, prev: CGPoint) -> FlakeHit {
        for i in stripIndices(at: f.p.x) {     // front-to-back: first hit wins (handles overlap)
            let (key, pile, isWindow) = stack[i]
            let rect = pile.frame
            guard f.p.x >= rect.minX, f.p.x < rect.maxX else { continue }
            let b = min(pile.h.count - 1, Int((f.p.x - rect.minX) / bucketW))
            guard pile.solid[b] else { continue }   // transparent part of an icon
            let surface = pile.top(b)
            guard f.p.y >= surface, f.p.y <= rect.maxY else { continue }
            // The flake is inside this surface's region. Did it just cross the top?
            if prev.y <= surface + 1 {
                if let j = pile.add(at: b, f.r * 0.35) { breakChunk(pile, key: key, at: j) }
                return .landed
            }
            // Blown into a window from the side: it stops there instead of drifting across.
            if isWindow, let side = sideEntered(prevX: prev.x, rect: rect) {
                pile.addWater(side: side, f.r * 0.35)
                return .side(x: side == 0 ? rect.minX - 0.5 : rect.maxX + 0.5)
            }
            return .none   // drifting in front of it (desktop icons, the Dock, the ground)
        }
        return .none
    }

    func update(dt: CGFloat) {
        t += dt
        wind = sin(t * 0.13) * 12 + sin(t * 0.37) * 5

        if flakes.isEmpty { flakes = (0..<flakeCount).map { _ in newFlake(anywhere: true) } }

        for i in flakes.indices {
            var f = flakes[i]
            if f.melt >= 0 {
                // Stuck to a window's side: slides down a little while it melts away.
                f.melt += dt / 1.5
                f.p.y += 6 * dt
                flakes[i] = f.melt >= 1 ? newFlake(anywhere: false) : f
                continue
            }
            let prev = f.p
            f.phase += dt * 1.3
            f.angle += f.spin * dt
            f.p.y += f.vy * dt
            f.p.x += (sin(f.phase) * f.sway + wind) * dt
            if f.p.x < desktop.minX - 20 { f.p.x = desktop.maxX }
            if f.p.x > desktop.maxX + 20 { f.p.x = desktop.minX }

            switch land(f, prev: prev) {
            case .landed:
                f = newFlake(anywhere: false)
            case .side(let x):
                f.p.x = x
                f.melt = 0
            case .none:
                if f.p.y > desktop.maxY + 5 { f = newFlake(anywhere: false) }
            }
            flakes[i] = f
        }

        // Landing clumps can break chunks off and add new clumps, so collect anew.
        let falling = clumps
        clumps = []
        clumps.reserveCapacity(falling.count)
        for var c in falling {
            let prevY = c.p.y
            c.v.dy += 900 * dt
            c.p.x += c.v.dx * dt
            c.p.y += c.v.dy * dt
            if c.p.y > desktop.maxY + 10 { continue }
            if c.lands, c.v.dy > 0, catchClump(&c, prevY: prevY) { continue }
            clumps.append(c)
        }

        updateElves(dt: dt)

        freezeClock += dt
        if freezeClock >= 2 {
            for pile in piles.values { pile.freeze(dt: freezeClock) }
            freezeClock = 0
        }
    }

    /// A falling clump crossing the top of a surface may stay there; where snow already
    /// lies it usually tumbles on (slower, a little sideways). Returns true if it stayed.
    private func catchClump(_ c: inout Clump, prevY: CGFloat) -> Bool {
        for i in stripIndices(at: c.p.x) {     // front-to-back, like flakes
            let (key, pile, _) = stack[i]
            let rect = pile.frame
            guard c.p.x >= rect.minX, c.p.x < rect.maxX else { continue }
            let b = min(pile.h.count - 1, Int((c.p.x - rect.minX) / bucketW))
            guard pile.solid[b] else { continue }
            let top = pile.top(b)
            guard c.p.y >= top, c.p.y <= rect.maxY else { continue }
            // In this surface's region: either crossing its top now, or falling in front of it.
            guard prevY <= top + 1, key != c.from, pile.visible[b] else { return false }
            if CGFloat.random(in: 0..<1) < pile.catchChance(at: b) {
                if let j = pile.add(at: b, clumpSnow(c.r)) { breakChunk(pile, key: key, at: j) }
                return true
            }
            c.from = key
            c.v.dy *= 0.5
            c.v.dx += .random(in: -30...30)
            return false
        }
        return false
    }

    // MARK: Elves

    /// Sends an elf to every ground that has snow on it (menu command).
    func sendElves() {
        for key in order where key.hasPrefix("ground") { sendElf(to: key) }
    }

    /// Height of the Dock on the screen whose bottom edge is `ground`, or on any
    /// screen if it's elsewhere, or a typical height if it isn't known.
    private func dockHeight(near ground: CGRect) -> CGFloat {
        let docks = axSurfaces.dock.map(\.rect)
        let here = docks.first { $0.minX < ground.maxX && $0.maxX > ground.minX && abs($0.maxY - ground.minY) < 200 }
        return (here ?? docks.first)?.height ?? World.defaultDockHeight
    }

    private func sendElf(to key: String) {
        guard let pile = piles[key], !elves.contains(where: { $0.ground == key }) else { return }
        let dir: CGFloat = -(lastElfDir[key] ?? -1)   // alternate sides, first from the left
        lastElfDir[key] = dir
        let x = dir > 0 ? pile.frame.minX - 40 : pile.frame.maxX + 40
        elves.append(Elf(ground: key, x: x, dir: dir, phase: 0))
    }

    private func updateElves(dt: CGFloat) {
        elfCheck += dt
        if elfCheck > 1 {
            elfCheck = 0
            for key in order where key.hasPrefix("ground") {
                guard let pile = piles[key], !elves.contains(where: { $0.ground == key }) else { continue }
                // Half the Dock's height, but never more than the ground can hold.
                let depthLimit = min(dockHeight(near: pile.frame) / 2, World.groundDepth * 0.7)
                let depth = pile.maxDepth, covered = pile.coveredFraction()
                if depth > depthLimit || covered > World.elfWidthThreshold {
                    NSLog("%@", "Elf to \(key): deepest \(Int(depth)) pt (limit \(Int(depthLimit))), covered \(Int(covered * 100))%")
                    sendElf(to: key)
                }
            }
        }
        elves = elves.compactMap { e in
            guard let pile = piles[e.ground] else { return nil }
            var e = e
            let oldBlade = e.x + e.dir * World.elfReach
            // Walks from 40 pt off one edge to 50 pt past the other in elfPassTime.
            e.x += e.dir * (pile.frame.width + 90) / World.elfPassTime * dt
            e.phase += dt * 8
            let newBlade = e.x + e.dir * World.elfReach
            shovel(pile, key: e.ground, columns: pile.columns(from: min(oldBlade, newBlade), to: max(oldBlade, newBlade)),
                   dir: e.dir)
            let gone = e.dir > 0 ? e.x > pile.frame.maxX + 50 : e.x < pile.frame.minX - 50
            return gone ? nil : e
        }
    }

    /// The elf's shovel clears these ground columns, tossing the snow back over its shoulder.
    private func shovel(_ pile: Pile, key: String, columns: Range<Int>, dir: CGFloat) {
        for b in columns where pile.h[b] > 0.3 {
            let h = pile.h[b]
            if pile.visible[b] {
                let x = pile.frame.minX + (CGFloat(b) + 0.5) * bucketW
                for _ in 0..<min(3, 1 + Int(h / 12)) {
                    clumps.append(Clump(
                        p: CGPoint(x: x, y: pile.frame.minY - h * .random(in: 0.3...1)),
                        v: CGVector(dx: -dir * .random(in: 30...130), dy: -.random(in: 160...330)),
                        r: .random(in: 1.8...3.2), from: key, lands: false))
                }
            }
            pile.h[b] = 0
        }
        if clumps.count > 8000 { clumps.removeFirst(clumps.count - 8000) }
    }
}

/// A little elf with a snow shovel, walking along the bottom of a screen.
struct Elf {
    let ground: String   // key of the ground pile it clears
    var x: CGFloat       // feet, global x
    let dir: CGFloat     // +1 walking right, -1 left
    var phase: CGFloat   // walk cycle
}
