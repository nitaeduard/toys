import AppKit
import QuartzCore

let flakeColor = CGColor(srgbRed: 0.86, green: 0.93, blue: 1.00, alpha: 0.95)
let pileColor  = CGColor(srgbRed: 0.93, green: 0.96, blue: 1.00, alpha: 0.97)
/// Packed ice and icicles: pale blue, a little see-through, so the snow and the
/// window behind tint it.
let iceColor = CGColor(srgbRed: 0.68, green: 0.85, blue: 0.98, alpha: 0.82)
let iceHighlight = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75)
let shadowColor = CGColor(srgbRed: 0.10, green: 0.20, blue: 0.40, alpha: 0.30)
/// Blur of the soft bluish shadow that keeps snow visible on white windows, in points.
let shadowBlur: CGFloat = 2.5

// MARK: - Bitmaps

/// Color space the bitmaps are drawn in: the display's own, so Core Animation can
/// show them as they are instead of converting every new image on the CPU.
/// Set from the main screen when the overlays are built.
nonisolated(unsafe) var renderColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

/// A bitmap context for `rect` (global top-left points) at `scale` pixels per point,
/// set up so drawing uses the same global, y-down coordinates as the simulation.
func makeContext(for rect: CGRect, scale: CGFloat) -> CGContext? {
    let pw = max(1, Int((rect.width * scale).rounded(.up)))
    let ph = max(1, Int((rect.height * scale).rounded(.up)))
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: renderColorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(ph))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: -rect.minX, y: -rect.minY)
    // Shadow blur is in device pixels for bitmap contexts, so scale it like the drawing.
    ctx.setShadow(offset: .zero, blur: shadowBlur * scale, color: shadowColor)
    return ctx
}

/// Pre-rendered, already-shadowed images of flakes and clumps, so a frame only moves
/// layers around instead of stroking and blurring paths.
@MainActor
enum Sprites {
    struct Sprite {
        let key: Int
        let image: CGImage
        let size: CGFloat      // points, square, centred on the flake/clump
        let radius: CGFloat    // the radius it was drawn for
    }
    /// Room around a shape for its shadow.
    static let margin: CGFloat = 4.5
    private static var cache: [Int: Sprite] = [:]

    /// Flake sprite for radius `r`, drawn at angle 0. Radii are bucketed in 0.2 pt
    /// steps; draw it scaled by `r / sprite.radius` (at most a few percent).
    static func flake(r: CGFloat, scale: CGFloat) -> Sprite {
        let q = Int((r * 5).rounded())
        let branched = r > 2               // bigger flakes have V-branches (bucket may straddle 2)
        let key = (q * 2 + (branched ? 1 : 0)) * 16 + Int(scale * 4)
        if let s = cache[key] { return s }
        let rb = CGFloat(q) / 5
        let len = rb * 1.5
        let half = (len + margin).rounded(.up)
        let rect = CGRect(x: -half, y: -half, width: half * 2, height: half * 2)
        let ctx = makeContext(for: rect, scale: scale)!
        let path = CGMutablePath()
        for k in 0..<6 {   // six arms; bigger flakes also get little V-branches
            let a = CGFloat(k) * .pi / 3
            let dir = CGPoint(x: cos(a), y: sin(a))
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: dir.x * len, y: dir.y * len))
            if branched {
                let b = CGPoint(x: dir.x * len * 0.55, y: dir.y * len * 0.55)
                for side in [-1.0, 1.0] as [CGFloat] {
                    let ba = a + side * .pi / 4
                    path.move(to: b)
                    path.addLine(to: CGPoint(x: b.x + cos(ba) * len * 0.38, y: b.y + sin(ba) * len * 0.38))
                }
            }
        }
        ctx.setStrokeColor(flakeColor)
        ctx.setLineWidth(0.9)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.strokePath()
        let s = Sprite(key: key, image: ctx.makeImage()!, size: half * 2, radius: rb)
        cache[key] = s
        return s
    }

    /// Round clump sprite for radius `r`, bucketed in 0.1 pt steps.
    static func clump(r: CGFloat, scale: CGFloat) -> Sprite {
        let q = Int((r * 10).rounded())
        let key = -(q * 16 + Int(scale * 4)) - 1
        if let s = cache[key] { return s }
        let rb = CGFloat(q) / 10
        let half = (rb + margin).rounded(.up)
        let rect = CGRect(x: -half, y: -half, width: half * 2, height: half * 2)
        let ctx = makeContext(for: rect, scale: scale)!
        ctx.setFillColor(pileColor)
        ctx.fillEllipse(in: CGRect(x: -rb, y: -rb, width: rb * 2, height: rb * 2))
        let s = Sprite(key: key, image: ctx.makeImage()!, size: half * 2, radius: rb)
        cache[key] = s
        return s
    }

    /// An angular ice shard for radius `r`, bucketed in 0.2 pt steps, in one of three shapes.
    static func shard(r: CGFloat, scale: CGFloat) -> Sprite {
        let q = Int((r * 5).rounded())
        let variant = q % 3
        let key = -(q * 16 + Int(scale * 4)) - 1_000_000
        if let s = cache[key] { return s }
        let rb = CGFloat(q) / 5
        let half = (rb * 1.6 + margin).rounded(.up)
        let rect = CGRect(x: -half, y: -half, width: half * 2, height: half * 2)
        let ctx = makeContext(for: rect, scale: scale)!
        let shapes: [[CGPoint]] = [
            [CGPoint(x: -0.4, y: -1.5), CGPoint(x: 0.7, y: -0.3), CGPoint(x: 0.2, y: 1.4), CGPoint(x: -0.7, y: 0.4)],
            [CGPoint(x: -1.2, y: -0.6), CGPoint(x: 1.1, y: -0.9), CGPoint(x: 0.5, y: 0.8)],
            [CGPoint(x: 0, y: -1.3), CGPoint(x: 0.8, y: 0), CGPoint(x: 0, y: 1.3), CGPoint(x: -0.6, y: 0.2)],
        ]
        let pts = shapes[variant].map { CGPoint(x: $0.x * rb, y: $0.y * rb) }
        ctx.setFillColor(iceColor)
        ctx.addLines(between: pts); ctx.closePath(); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(iceHighlight); ctx.setLineWidth(0.6); ctx.setLineCap(.round)
        ctx.move(to: pts[0]); ctx.addLine(to: pts[1]); ctx.strokePath()
        let s = Sprite(key: key, image: ctx.makeImage()!, size: half * 2, radius: rb)
        cache[key] = s
        return s
    }

    /// The elf, facing right, in two walking poses. `rect` is in local points
    /// (y down) with the feet at the origin.
    struct ElfSprite {
        let image: CGImage
        let rect: CGRect
    }
    private static var elfCache: [Int: ElfSprite] = [:]

    static func clearCache() {
        cache.removeAll()
        elfCache.removeAll()
    }

    static func elf(pose: Int, scale: CGFloat) -> ElfSprite {
        let key = pose * 16 + Int(scale * 4)
        if let s = elfCache[key] { return s }
        let rect = CGRect(x: -20, y: -56, width: 52, height: 60)
        let ctx = makeContext(for: rect, scale: scale)!
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        let green = rgb(0.13, 0.55, 0.25), darkGreen = rgb(0.08, 0.33, 0.16), red = rgb(0.80, 0.12, 0.14)
        let skin = rgb(0.98, 0.82, 0.68), white = rgb(0.97, 0.98, 1), brown = rgb(0.42, 0.25, 0.12)
        let steel = rgb(0.62, 0.67, 0.73), dark = rgb(0.12, 0.10, 0.10), gold = rgb(0.95, 0.75, 0.20)
        func line(_ a: CGPoint, _ b: CGPoint, _ c: CGColor, _ w: CGFloat) {
            ctx.setStrokeColor(c); ctx.setLineWidth(w); ctx.setLineCap(.round)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        }
        func circle(_ c: CGPoint, _ r: CGFloat, _ color: CGColor) {
            ctx.setFillColor(color); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        func fill(_ pts: [CGPoint], _ color: CGColor) {
            ctx.setFillColor(color); ctx.addLines(between: pts); ctx.closePath(); ctx.fillPath()
        }

        // Legs and boots, swinging with the pose.
        let swing: CGFloat = pose == 0 ? 3.5 : -3.5
        for (hip, foot) in [(CGFloat(-2.5), -2.5 - swing), (2.5, 2.5 + swing)] {
            line(CGPoint(x: hip, y: -12), CGPoint(x: foot, y: -2.5), darkGreen, 3.4)
            ctx.setFillColor(brown)
            ctx.fillEllipse(in: CGRect(x: foot - 2.5, y: -3.8, width: 7, height: 3.8))
        }
        // Shovel: handle from the hands down to a blade scooping snow ahead.
        line(CGPoint(x: 3, y: -22), CGPoint(x: 21, y: -4), brown, 2)
        fill([CGPoint(x: 18, y: -7), CGPoint(x: 29, y: -3.5), CGPoint(x: 28, y: 1), CGPoint(x: 16, y: -1)], steel)
        circle(CGPoint(x: 23, y: -4.5), 3.2, white)
        // Tunic with belt and buckle.
        ctx.setFillColor(red)
        ctx.addPath(CGPath(roundedRect: CGRect(x: -7.5, y: -27, width: 15, height: 16), cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(dark); ctx.fill(CGRect(x: -7.5, y: -17.5, width: 15, height: 2.4))
        ctx.setFillColor(gold); ctx.fill(CGRect(x: -1.6, y: -18.2, width: 3.2, height: 3.6))
        // Arm reaching to the shovel, with a mitten.
        line(CGPoint(x: 1, y: -24), CGPoint(x: 8, y: -17), red, 3.4)
        circle(CGPoint(x: 9, y: -16.2), 2.3, green)
        // Head: face, pointy ear, eye, rosy cheek.
        fill([CGPoint(x: -4, y: -35), CGPoint(x: -11, y: -38), CGPoint(x: -5, y: -31)], skin)
        circle(CGPoint(x: 0, y: -33), 6.2, skin)
        circle(CGPoint(x: 3.2, y: -33.8), 0.95, dark)
        circle(CGPoint(x: 3.6, y: -30.8), 1.3, rgb(0.97, 0.62, 0.60))
        // Hat: green cone flopping backwards, white band and pompom.
        ctx.setFillColor(green)
        ctx.move(to: CGPoint(x: -7, y: -38))
        ctx.addQuadCurve(to: CGPoint(x: -15, y: -52), control: CGPoint(x: -4, y: -50))
        ctx.addQuadCurve(to: CGPoint(x: 7, y: -38), control: CGPoint(x: 5, y: -49))
        ctx.closePath(); ctx.fillPath()
        ctx.setFillColor(white)
        ctx.addPath(CGPath(roundedRect: CGRect(x: -7.8, y: -40, width: 15.6, height: 3.6), cornerWidth: 1.8, cornerHeight: 1.8, transform: nil))
        ctx.fillPath()
        circle(CGPoint(x: -15, y: -52), 2.8, white)

        let s = ElfSprite(image: ctx.makeImage()!, rect: rect)
        elfCache[key] = s
        return s
    }
}

// MARK: - Rendering

/// A slice of a pile. It draws its paths straight into Core Animation's own backing
/// store (in the display's format), so a redraw costs only the drawing; handing CA a
/// new bitmap instead makes it convert every image on the CPU.
final class TileLayer: CALayer {
    struct Paths {
        var rect: CGRect              // global top-left coords of this layer
        var snow, iceFill, iceShine, icicleFill, icicleShine: CGPath
    }
    var paths: Paths?

    override func draw(in ctx: CGContext) {
        guard let p = paths else { return }
        // Layer contexts are y-up; draw in the simulation's global, y-down coords.
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -p.rect.minX, y: -p.rect.minY)
        // In a layer's own context the shadow blur is in points (unlike bitmap contexts).
        ctx.setShadow(offset: .zero, blur: shadowBlur, color: shadowColor)
        // Icicles hang behind the snow drape; the ice band tints the bottom of the pile.
        ctx.setFillColor(iceColor)
        ctx.addPath(p.icicleFill)
        ctx.fillPath()
        ctx.setFillColor(pileColor)
        ctx.addPath(p.snow)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)   // the snow's shadow is enough
        ctx.setFillColor(iceColor)
        ctx.addPath(p.iceFill)
        ctx.fillPath()
        ctx.setStrokeColor(iceHighlight)
        ctx.setLineCap(.round)
        ctx.setLineWidth(0.7)
        ctx.addPath(p.iceShine)
        ctx.addPath(p.icicleShine)
        ctx.strokePath()
    }
}

/// One overlay per screen. Layer-hosting: piles are tiles drawn by Core Animation,
/// each redrawn only when its columns change; flakes, falling clumps and elves are
/// sprite layers moved every frame.
final class SnowView: NSView {
    let world: World
    let origin: CGPoint   // this screen's top-left in global top-left coords
    let scale: CGFloat

    private let pileRoot = CALayer()
    private let clumpLayer = CALayer()
    private var clumpLayers: [(layer: CALayer, spriteKey: Int?)] = []
    /// More falling clumps than this on one screen aren't drawn (only briefly, after
    /// a huge pile falls).
    private static let maxClumpLayers = 2500
    private let flakeRoot = CALayer()
    private let elfRoot = CALayer()
    private var elfLayers: [CALayer] = []

    /// Columns per pile tile (192 pt). A landing flake only redraws its tile.
    private static let tileColumns = 64
    /// Columns drawn beyond each side of a tile so the cut-off shapes (and their
    /// shadows) stay outside it; a run's outline at a column only depends on its neighbours.
    private static let tileOverlap = 4

    /// The pile data a tile was drawn from.
    private struct TileSnapshot: Equatable {
        var h: [CGFloat], drape: [CGFloat], ice: [CGFloat], visible: [Bool], drapeVisible: [Bool]
        var icicles: [Icicle]
        init(_ pile: Pile, _ cols: Range<Int>, icicles: [Icicle]) {
            h = Array(pile.h[cols]); drape = Array(pile.drape[cols])
            ice = cols.map(pile.iceDepth)
            visible = Array(pile.visible[cols]); drapeVisible = Array(pile.drapeVisible[cols])
            self.icicles = icicles.filter { cols.contains($0.column) && pile.drapeVisible[$0.column] }
        }
    }
    private struct Tile {
        let layer: TileLayer
        var snapshot: TileSnapshot?
    }
    private struct CachedPile {
        weak var pile: Pile?
        var snowVersion: Int
        var visibilityVersion: Int
        var tiles: [Tile]
    }
    private var pileLayers: [String: CachedPile] = [:]

    private struct FlakeLayer {
        let layer: CALayer
        var spriteKey: Int?
        var hidden: Bool
    }
    private var flakeLayers: [FlakeLayer] = []

    init(world: World, frame: NSRect, origin: CGPoint, scale: CGFloat) {
        self.world = world
        self.origin = origin
        self.scale = scale
        super.init(frame: frame)
        let root = CALayer()
        layer = root            // set before wantsLayer: a layer-hosting view
        wantsLayer = true
        for l in [pileRoot, clumpLayer, elfRoot, flakeRoot] {
            l.frame = bounds
            l.contentsScale = scale
            root.addSublayer(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Global top-left rect → frame in the (bottom-left) layer space.
    private func layerFrame(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - origin.x, y: bounds.height - (r.maxY - origin.y), width: r.width, height: r.height)
    }

    private func newLayer() -> CALayer {
        let l = CALayer()
        l.contentsScale = scale
        return l
    }

    /// Updates the layers for the current state of the world. Call once per frame.
    func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let screen = CGRect(origin: origin, size: bounds.size)
        let area = screen.insetBy(dx: -10, dy: -30)
        renderPiles(area: area, screen: screen)
        renderClumps(area: area, screen: screen)
        renderElves(screen: screen)
        renderFlakes(area: area)
        CATransaction.commit()
    }

    // MARK: Piles

    /// For each run of included columns, adds a closed shape whose outer edge is a
    /// smooth curve through `outer` points and whose inner edge follows `inner`.
    private func addRuns(_ path: CGMutablePath, columns: Range<Int>, include: (Int) -> Bool,
                         outer: (Int) -> CGPoint, inner: (Int) -> CGPoint) {
        var b = columns.lowerBound
        let n = columns.upperBound
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

    /// Open smooth curve through the outer points of each run (for the ice highlight).
    private func addOuterCurves(_ path: CGMutablePath, columns: Range<Int>, include: (Int) -> Bool,
                                outer: (Int) -> CGPoint) {
        var b = columns.lowerBound
        while b < columns.upperBound {
            guard include(b) else { b += 1; continue }
            let start = b
            while b < columns.upperBound, include(b) { b += 1 }
            let pts = (start..<b).map(outer)
            guard pts.count > 1 else { continue }
            path.move(to: pts[0])
            for k in 1..<pts.count {
                let mid = CGPoint(x: (pts[k - 1].x + pts[k].x) / 2, y: (pts[k - 1].y + pts[k].y) / 2)
                path.addQuadCurve(to: mid, control: pts[k - 1])
            }
            path.addLine(to: pts[pts.count - 1])
        }
    }

    /// The icy band at the bottom of the pile, and a highlight along its top.
    private func icePaths(_ pile: Pile, columns: Range<Int>) -> (fill: CGPath, shine: CGPath) {
        let fill = CGMutablePath(), shine = CGMutablePath()
        let x0 = pile.frame.minX, y0 = pile.frame.minY
        func cx(_ k: Int) -> CGFloat { x0 + (CGFloat(k) + 0.5) * bucketW }
        let include = { (k: Int) in pile.visible[k] && pile.iceDepth(k) > 0.4 }
        addRuns(fill, columns: columns, include: include,
                outer: { CGPoint(x: cx($0), y: y0 + pile.base[$0] - pile.iceDepth($0)) },
                inner: { CGPoint(x: cx($0), y: y0 + pile.base[$0] + 0.5) })
        addOuterCurves(shine, columns: columns, include: { include($0) && pile.iceDepth($0) > 1.5 },
                       outer: { CGPoint(x: cx($0), y: y0 + pile.base[$0] - pile.iceDepth($0) + 0.9) })
        return (fill, shine)
    }

    /// Icicles: slightly curved cones, with a highlight down one side.
    private func iciclePaths(_ icicles: [Icicle]) -> (fill: CGPath, shine: CGPath) {
        let fill = CGMutablePath(), shine = CGMutablePath()
        for ic in icicles {
            let l = ic.x - ic.width / 2, r = ic.x + ic.width / 2, tip = CGPoint(x: ic.x + ic.width * 0.1, y: ic.top + ic.length)
            fill.move(to: CGPoint(x: l, y: ic.top - 1))
            fill.addLine(to: CGPoint(x: r, y: ic.top - 1))
            fill.addQuadCurve(to: tip, control: CGPoint(x: r - ic.width * 0.1, y: ic.top + ic.length * 0.45))
            fill.addQuadCurve(to: CGPoint(x: l, y: ic.top - 1), control: CGPoint(x: l + ic.width * 0.05, y: ic.top + ic.length * 0.5))
            fill.closeSubpath()
            if ic.length > 4 {
                shine.move(to: CGPoint(x: l + ic.width * 0.3, y: ic.top + 1))
                shine.addLine(to: CGPoint(x: ic.x - ic.width * 0.05, y: ic.top + ic.length * 0.6))
            }
        }
        return (fill, shine)
    }

    /// Piles (above the edge) and drapes (overflow hanging over the front): one smooth
    /// blob per contiguous run of columns, hugging the rounded corners.
    private func pilePath(_ pile: Pile, columns: Range<Int>) -> CGPath {
        let path = CGMutablePath()
        let x0 = pile.frame.minX, y0 = pile.frame.minY
        func cx(_ k: Int) -> CGFloat { x0 + (CGFloat(k) + 0.5) * bucketW }
        // Above the edge: outer = snow surface, inner = window edge.
        addRuns(path, columns: columns, include: { pile.visible[$0] && pile.h[$0] > 0.3 },
                outer: { CGPoint(x: cx($0), y: pile.top($0)) },
                inner: { CGPoint(x: cx($0), y: y0 + pile.base[$0] + 0.5) })
        // Below the edge: outer = hanging tip, inner = window edge.
        addRuns(path, columns: columns, include: { pile.drapeVisible[$0] && pile.drape[$0] > 0.5 },
                outer: { CGPoint(x: cx($0), y: y0 + pile.base[$0] + pile.drape[$0]) },
                inner: { CGPoint(x: cx($0), y: y0 + pile.base[$0] - 0.5) })
        return path
    }

    private func renderPiles(area: CGRect, screen: CGRect) {
        var seen = Set<String>()
        for key in world.order {
            guard let pile = world.piles[key], pile.frame.intersects(area) else { continue }
            seen.insert(key)
            var cached: CachedPile
            if let c = pileLayers[key], c.pile === pile {
                if c.snowVersion == pile.snowVersion, c.visibilityVersion == pile.visibilityVersion { continue }
                cached = c
            } else {
                pileLayers[key]?.tiles.forEach { $0.layer.removeFromSuperlayer() }
                let count = (pile.h.count + Self.tileColumns - 1) / Self.tileColumns
                cached = CachedPile(pile: pile, snowVersion: -1, visibilityVersion: -1, tiles: (0..<count).map { _ in
                    let l = TileLayer()
                    l.contentsScale = scale
                    l.isHidden = true
                    pileRoot.addSublayer(l)
                    return Tile(layer: l, snapshot: nil)
                })
            }
            cached.snowVersion = pile.snowVersion
            cached.visibilityVersion = pile.visibilityVersion
            for t in cached.tiles.indices { renderTile(&cached.tiles[t], index: t, of: pile, screen: screen) }
            pileLayers[key] = cached
        }
        for (key, c) in pileLayers where !seen.contains(key) {
            c.tiles.forEach { $0.layer.removeFromSuperlayer() }
            pileLayers[key] = nil
        }
    }

    /// Redraws one tile of a pile if the columns it shows have changed.
    private func renderTile(_ tile: inout Tile, index t: Int, of pile: Pile, screen: CGRect) {
        let n = pile.h.count
        let cols = (t * Self.tileColumns)..<min(n, (t + 1) * Self.tileColumns)
        let ext = max(0, cols.lowerBound - Self.tileOverlap)..<min(n, cols.upperBound + Self.tileOverlap)
        let snapshot = TileSnapshot(pile, ext, icicles: pile.icicles())
        guard snapshot != tile.snapshot else { return }
        tile.snapshot = snapshot
        let layer = tile.layer

        let snow = pilePath(pile, columns: ext)
        let ice = icePaths(pile, columns: ext)
        let icicles = iciclePaths(snapshot.icicles)
        let path = CGMutablePath()
        path.addPath(snow)
        path.addPath(icicles.fill)
        // Tiles meet at whole points, so neighbours neither overlap nor leave gaps;
        // the outer tiles also take the shadow beyond the pile's ends.
        let x0 = pile.frame.minX
        let left = cols.lowerBound == 0 ? -CGFloat.infinity : floor(x0 + CGFloat(cols.lowerBound) * bucketW)
        let right = cols.upperBound == n ? CGFloat.infinity : floor(x0 + CGFloat(cols.upperBound) * bucketW)
        var rect = CGRect.null
        if !path.isEmpty {
            let box = path.boundingBoxOfPath.insetBy(dx: -Sprites.margin, dy: -Sprites.margin).integral
            let minX = max(box.minX, left), maxX = min(box.maxX, right)
            if minX < maxX {
                rect = CGRect(x: minX, y: box.minY, width: maxX - minX, height: box.height).intersection(screen)
            }
        }
        guard !rect.isNull, !rect.isEmpty else {
            if !layer.isHidden { layer.paths = nil; layer.contents = nil; layer.isHidden = true }
            return
        }
        layer.paths = TileLayer.Paths(rect: rect, snow: snow, iceFill: ice.fill, iceShine: ice.shine,
                                      icicleFill: icicles.fill, icicleShine: icicles.shine)
        layer.frame = layerFrame(rect)
        layer.isHidden = false
        layer.setNeedsDisplay()
    }

    // MARK: Clumps

    /// Falling clumps and ice shards: one sprite layer each, from a pool. Sprite images
    /// are reused, so Core Animation prepares each only once.
    private func renderClumps(area: CGRect, screen: CGRect) {
        let height = bounds.height
        var used = 0
        for c in world.clumps where area.contains(c.p) {
            guard used < Self.maxClumpLayers else { break }
            if used == clumpLayers.count {
                let l = newLayer()
                clumpLayer.addSublayer(l)
                clumpLayers.append((l, nil))
            }
            let l = clumpLayers[used].layer
            let s = c.ice ? Sprites.shard(r: c.r, scale: scale) : Sprites.clump(r: c.r, scale: scale)
            if clumpLayers[used].spriteKey != s.key {
                clumpLayers[used].spriteKey = s.key
                l.contents = s.image
                l.bounds = CGRect(x: 0, y: 0, width: s.size, height: s.size)
            }
            if l.isHidden { l.isHidden = false }
            l.position = CGPoint(x: c.p.x - origin.x, y: height - (c.p.y - origin.y))
            let k = c.r / s.radius
            l.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
            used += 1
        }
        for i in used..<clumpLayers.count where !clumpLayers[i].layer.isHidden {
            clumpLayers[i].layer.isHidden = true
        }
    }

    // MARK: Elves

    private func renderElves(screen: CGRect) {
        var used = 0
        for e in world.elves {
            guard let ground = world.piles[e.ground]?.frame, ground.intersects(screen.insetBy(dx: 0, dy: -2)) else { continue }
            if used == elfLayers.count {
                let l = newLayer()
                elfRoot.addSublayer(l)
                elfLayers.append(l)
            }
            let l = elfLayers[used]
            used += 1
            let pose = Int(e.phase) % 2
            let s = Sprites.elf(pose: pose, scale: scale)
            if l.contents as! CGImage? !== s.image {
                l.contents = s.image
                l.bounds = CGRect(origin: .zero, size: s.rect.size)
                // Feet (local origin) as the anchor; the layer space is y-up.
                l.anchorPoint = CGPoint(x: -s.rect.minX / s.rect.width, y: s.rect.maxY / s.rect.height)
            }
            l.isHidden = false
            let bob: CGFloat = pose == 0 ? 0 : 1
            l.position = CGPoint(x: e.x - origin.x, y: bounds.height - (ground.minY - origin.y) + bob)
            l.setAffineTransform(CGAffineTransform(scaleX: e.dir, y: 1))
        }
        for l in elfLayers[used...] where !l.isHidden { l.isHidden = true; l.contents = nil }
    }

    // MARK: Flakes

    /// One sprite layer per flake; flakes elsewhere are hidden on this screen.
    private func renderFlakes(area: CGRect) {
        let flakes = world.flakes
        while flakeLayers.count < flakes.count {
            let l = newLayer()
            l.isHidden = true
            flakeRoot.addSublayer(l)
            flakeLayers.append(FlakeLayer(layer: l, spriteKey: nil, hidden: true))
        }
        while flakeLayers.count > flakes.count { flakeLayers.removeLast().layer.removeFromSuperlayer() }

        let height = bounds.height
        for i in flakes.indices {
            let f = flakes[i]
            let show = area.contains(f.p)
            if show != !flakeLayers[i].hidden {
                flakeLayers[i].hidden = !show
                flakeLayers[i].layer.isHidden = !show
            }
            guard show else { continue }
            let l = flakeLayers[i].layer
            let s = Sprites.flake(r: f.r, scale: scale)
            if flakeLayers[i].spriteKey != s.key {
                flakeLayers[i].spriteKey = s.key
                l.contents = s.image
                l.bounds = CGRect(x: 0, y: 0, width: s.size, height: s.size)
            }
            l.position = CGPoint(x: f.p.x - origin.x, y: height - (f.p.y - origin.y))
            // A flake melting against a window shrinks away.
            let k = f.r / s.radius * (f.melt >= 0 ? max(0.1, 1 - f.melt * 0.9) : 1)
            // The layer space is y-up, so the angle turns the other way.
            l.setAffineTransform(CGAffineTransform(rotationAngle: -f.angle).scaledBy(x: k, y: k))
        }
    }
}
