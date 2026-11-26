import AppKit

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
