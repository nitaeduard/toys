import AppKit

@MainActor
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

    /// Drives frames at the display's refresh rate (capped at 60 Hz); created per
    /// overlay rebuild on the first screen's view.
    var displayLink: CADisplayLink?
    var pollTimer: Timer?
    var axTimer: Timer?

    /// Reasons to stop animating and polling (Low Power Mode is read when needed).
    enum PauseReason: String, Sendable { case screensAsleep, sessionInactive, screenLocked }
    var pauseReasons: Set<PauseReason> = []
    private(set) var paused = false
    
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
        // Observers and timers below are delivered on the main queue / main run loop.
        ws.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = Int(app.processIdentifier)
            MainActor.assumeIsolated { self?.world.recentlyHidden[pid] = CACurrentMediaTime() }
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.world.lastSpaceChange = CACurrentMediaTime() }
        }
        observePauseReasons()
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "❄︎"
        let menu = NSMenu()
        menu.delegate = self
        let clear = NSMenuItem(title: "Clear Snow", action: #selector(clearSnow), keyEquivalent: "")
        clear.target = self
        axItem = NSMenuItem(title: "Snow on Dock & Desktop Icons", action: #selector(toggleAX), keyEquivalent: "")
        axItem.target = self
        let elf = NSMenuItem(title: "Send the Elf", action: #selector(sendElf), keyEquivalent: "")
        elf.target = self
        menu.addItem(clear)
        menu.addItem(elf)
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
        updatePaused()
        if !paused { startPolling() }
    }

    // MARK: Pausing

    /// Pause while nobody can see the snow (screens asleep, screen locked, user switched
    /// away) and in Low Power Mode. The snow stays where it is.
    func observePauseReasons() {
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, PauseReason, Bool)] = [
            (ws, NSWorkspace.screensDidSleepNotification, .screensAsleep, true),
            (ws, NSWorkspace.screensDidWakeNotification, .screensAsleep, false),
            (ws, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (ws, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
            (dnc, Notification.Name("com.apple.screenIsLocked"), .screenLocked, true),
            (dnc, Notification.Name("com.apple.screenIsUnlocked"), .screenLocked, false),
        ]
        for (center, name, reason, active) in events {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if active { self.pauseReasons.insert(reason) } else { self.pauseReasons.remove(reason) }
                    self.updatePaused()
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePaused() }
        }
    }

    func updatePaused() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let shouldPause = !pauseReasons.isEmpty || lowPower
        guard shouldPause != paused else { return }
        paused = shouldPause
        let why = pauseReasons.map(\.rawValue).sorted() + (lowPower ? ["lowPower"] : [])
        NSLog("%@", "Snowfall \(paused ? "paused" : "resumed") \(why)")
        if paused {
            displayLink?.isPaused = true
            pollTimer?.invalidate(); pollTimer = nil
            axTimer?.invalidate(); axTimer = nil
        } else {
            lastTick = CACurrentMediaTime()   // no jump in dt after the pause
            world.refreshSurfaces()
            startPolling()
            displayLink?.isPaused = false
        }
    }

    /// Window list and Accessibility polling, 10x/s each.
    func startPolling() {
        guard pollTimer == nil else { return }
        let poll = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.world.refreshSurfaces() }
        }
        let ax = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanAX() }
        }
        for t in [poll, ax] { RunLoop.main.add(t, forMode: .common) }
        pollTimer = poll
        axTimer = ax
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
        let key = "AXTrustedCheckOptionPrompt"   // kAXTrustedCheckOptionPrompt, a global var Swift 6 won't read
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
    
    @objc func buildOverlays() {
        displayLink?.invalidate()
        displayLink = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        guard let primary = NSScreen.screens.first?.frame else { return }
        
        var desktop = CGRect.null
        var screens: [CGRect] = []
        for screen in NSScreen.screens {
            let f = screen.frame
            // Convert AppKit (bottom-left) to global top-left coords.
            let origin = CGPoint(x: f.minX, y: primary.maxY - f.maxY)
            desktop = desktop.union(CGRect(origin: origin, size: f.size))
            screens.append(CGRect(origin: origin, size: f.size))
            
            let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(f, display: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.contentView = SnowView(world: world, frame: NSRect(origin: .zero, size: f.size), origin: origin,
                                     scale: screen.backingScaleFactor)
            w.orderFrontRegardless()
            overlays.append(w)
        }
        world.desktop = desktop
        world.screens = screens
        if let space = (NSScreen.main ?? NSScreen.screens.first)?.colorSpace?.cgColorSpace,
           space.model == .rgb, space !== renderColorSpace {
            renderColorSpace = space
            Sprites.clearCache()   // redrawn in the new space
        }

        // One frame clock for all screens, from the first screen's display.
        if let view = overlays.first?.contentView {
            let link = view.displayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.isPaused = paused
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc func step(_ link: CADisplayLink) { tick() }
    
    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        world.update(dt: CGFloat(dt))
        for w in overlays { (w.contentView as? SnowView)?.render() }
    }
    
    @objc func clearSnow() { world.clearSnow() }
    @objc func sendElf() { world.sendElves() }
}
