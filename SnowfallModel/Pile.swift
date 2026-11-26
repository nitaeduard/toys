// Snow model shared by the app and its tests: surfaces and their snow piles.

import CoreGraphics
import Foundation

let bucketW: CGFloat = 3      // width of one height-map column, in points

struct Flake {
    var p: CGPoint
    var vy, r, phase, sway, angle, spin: CGFloat
    /// 0...1 while melting against the side of a window, -1 otherwise.
    var melt: CGFloat = -1
}

/// Which side of `rect` a point moving from `prevX` entered through: 0 = left,
/// 1 = right, nil if it was already within the rect's horizontal span.
func sideEntered(prevX: CGFloat, rect: CGRect) -> Int? {
    if prevX < rect.minX { return 0 }
    if prevX >= rect.maxX { return 1 }
    return nil
}

struct Clump {
    var p: CGPoint
    var v: CGVector
    var r: CGFloat
    /// Key of the surface it came from or last bounced over; it can't land there again.
    var from: String? = nil
    /// false: falls off the screen without landing (snow from the Dock, the ground,
    /// thrown by the elf, and all ice).
    var lands = true
    /// An ice shard rather than a lump of snow.
    var ice = false
}

/// An icicle hanging from a surface's top edge, global coords (y down).
struct Icicle: Equatable {
    var x: CGFloat        // centre
    var top: CGFloat      // where it hangs from
    var width: CGFloat    // at the top
    var length: CGFloat
    var column: Int       // pile column it hangs under
}

/// Snow a clump of radius r stands for (the inverse of how piles are broken into clumps).
func clumpSnow(_ r: CGFloat) -> CGFloat { r * 1.6 }

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
    var h: [CGFloat] { didSet { snowVersion &+= 1 } }        // snow depth per column
    let base: [CGFloat]         // how far the surface dips below frame.minY (rounded corners)
    let capH: [CGFloat]         // max depth per column: less on corners, lumpy elsewhere
    let solid: [Bool]           // false where the surface has no shape (transparent icon column)
    let flat: [Bool]            // gentle enough for overflow to hang down from
    var visible: [Bool] { didSet { visibilityVersion &+= 1 } }      // false where something in front covers this edge
    var drape: [CGFloat] { didSet { snowVersion &+= 1 } }   // overflow snow hanging down over the surface's front
    var drapeVisible: [Bool] { didSet { visibilityVersion &+= 1 } }
    var breakAt: [CGFloat]      // drape length at which a chunk breaks off
    let maxDrape: CGFloat
    /// Ice at the bottom of each column (part of `h`, never more than it): old snow
    /// that has packed down. Changes are written in 0.5 pt steps.
    var ice: [CGFloat] { didSet { snowVersion &+= 1 } }
    /// Seconds each column has held snow without being cleared.
    private(set) var age: [CGFloat]
    /// Exact ice depth; `ice` follows it in coarse steps.
    private var iceExact: [CGFloat]
    /// Melt water collected on the left (0) and right (1) sides.
    private(set) var water: [CGFloat] = [0, 0]
    /// Length of the longest icicle at the left (0) and right (1) top corner, in 0.5 pt steps.
    private(set) var icicleLength: [CGFloat] = [0, 0] { didSet { snowVersion &+= 1 } }
    /// Per corner, per icicle: offset inward from the end of the rounded corner,
    /// and length/width relative to the longest one. Fixed per pile.
    private let icicleLayout: [[(dx: CGFloat, scale: CGFloat)]]
    let cornerRadius: CGFloat

    /// Bumped whenever `h` or `drape` change (the renderer and the visibility check
    /// compare these to skip work when nothing moved).
    private(set) var snowVersion = 0
    /// Bumped whenever `visible` or `drapeVisible` change.
    private(set) var visibilityVersion = 0
    /// What `updateVisibility` last computed from, to skip identical recomputations.
    private var visibilityInput: (front: [CGRect], snowVersion: Int)?

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
        ice = Array(repeating: 0, count: n)
        age = Array(repeating: 0, count: n)
        iceExact = Array(repeating: 0, count: n)
        cornerRadius = r
        icicleLayout = (0..<2).map { _ in
            [(CGFloat(2), CGFloat(1)), (7, 0.6), (12, 0.35)].map { dx, scale in
                (dx + .random(in: -1...1), scale * .random(in: 0.85...1.15))
            }
        }
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
            ice[i] = min(h[i], old.ice[j])
            iceExact[i] = min(h[i], old.iceExact[j])
            age[i] = old.age[j]
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
        if h[j] != capH[j] { h[j] = capH[j] }   // avoid bumping snowVersion for nothing
        guard maxDrape > 0, flat[j] else { return nil }   // on a corner it just slides off

        drape[j] += amount * 2.5
        // Share with neighbours so it hangs in soft lumps instead of spikes.
        for k in [j - 1, j + 1] where k >= 0 && k < h.count && flat[k] {
            let d = drape[j] - drape[k]
            if d > 2 { drape[k] += d * 0.35; drape[j] -= d * 0.2 }
        }
        return drape[j] > breakAt[j] ? j : nil
    }

    // MARK: Ice

    /// Snow starts turning to ice after lying this long, in seconds...
    static let iceStart: CGFloat = 120
    /// ...then the rest of it freezes with this time constant (about 90% ice
    /// 8 minutes later, so mostly ice ~10 minutes after it settled).
    static let iceTimeConstant: CGFloat = 200
    /// Longest icicle relative to the surface's drape length.
    static let icicleScale: CGFloat = 1

    /// Ages the snow by `dt` seconds: columns that have held snow long enough slowly
    /// turn to ice from the bottom up. Empty columns start over.
    func freeze(dt: CGFloat) {
        var newIce = ice
        for i in h.indices {
            guard h[i] >= 0.3 else {
                age[i] = 0
                iceExact[i] = 0
                newIce[i] = 0
                continue
            }
            age[i] += dt
            var v = min(iceExact[i], h[i])
            if age[i] > Pile.iceStart {
                v += (h[i] - v) * (1 - exp(-dt / Pile.iceTimeConstant))
            }
            iceExact[i] = v
            // Clamp right away when snow was removed; otherwise only publish 0.5 pt
            // steps, so the renderer redraws rarely.
            if newIce[i] > h[i] || v - newIce[i] >= 0.5 { newIce[i] = v }
        }
        if newIce != ice { ice = newIce }
    }

    /// Ice actually shown at column i (snow knocked off the top can leave less snow
    /// than ice until the next `freeze`).
    func iceDepth(_ i: Int) -> CGFloat { min(ice[i], h[i]) }

    /// A melting flake's water runs down the side; it freezes into icicles at that
    /// top corner. Their length grows with the square root of the water, up to the
    /// surface's drape length.
    func addWater(side: Int, _ amount: CGFloat) {
        guard maxDrape > 0 else { return }
        water[side] += amount
        let len = min(maxDrape * Pile.icicleScale, 2.6 * sqrt(water[side]))
        let q = (len * 2).rounded(.down) / 2
        if q != icicleLength[side] { icicleLength[side] = q }
    }

    func clearIcicles() {
        water = [0, 0]
        if icicleLength != [0, 0] { icicleLength = [0, 0] }
    }

    /// The icicles hanging under the flat part of the top edge, next to each corner.
    func icicles() -> [Icicle] {
        var out: [Icicle] = []
        for side in 0..<2 where icicleLength[side] >= 1 {
            for (dx, scale) in icicleLayout[side] {
                let inset = cornerRadius + dx
                let x = side == 0 ? frame.minX + inset : frame.maxX - inset
                guard x > frame.minX, x < frame.maxX else { continue }
                let col = min(h.count - 1, max(0, Int((x - frame.minX) / bucketW)))
                let len = icicleLength[side] * scale
                guard len >= 1 else { continue }
                out.append(Icicle(x: x, top: frame.minY + base[col], width: 2 + len * 0.12,
                                  length: len, column: col))
            }
        }
        return out
    }

    // MARK: Falling snow

    /// How full column i is, 0...1 (a column that holds nothing counts as full).
    func fill(_ i: Int) -> CGFloat { capH[i] > 0 ? min(1, h[i] / capH[i]) : 1 }

    /// Chance that a falling clump crossing column i stays there: high on bare
    /// surface, low where snow already lies, so most of it tumbles on and cascades.
    func catchChance(at i: Int) -> CGFloat {
        guard solid[i] else { return 0 }
        return 0.05 + 0.8 * pow(1 - fill(i), 1.5)
    }

    /// Deepest snow in any column.
    var maxDepth: CGFloat { h.max() ?? 0 }

    /// Fraction of the solid columns with more than `minDepth` of snow.
    func coveredFraction(minDepth: CGFloat = 1) -> CGFloat {
        var covered = 0, total = 0
        for i in h.indices where solid[i] {
            total += 1
            if h[i] > minDepth { covered += 1 }
        }
        return total > 0 ? CGFloat(covered) / CGFloat(total) : 0
    }

    /// Columns whose centres lie in [lo, hi) (global x).
    func columns(from lo: CGFloat, to hi: CGFloat) -> Range<Int> {
        let a = max(0, Int(ceil((lo - frame.minX) / bucketW - 0.5)))
        let b = min(h.count, Int(ceil((hi - frame.minX) / bucketW - 0.5)))
        return a < b ? a..<b : 0..<0
    }

    // MARK: Covered columns

    /// Hides the columns covered by something further in front: a column's snow is
    /// hidden if a front rect contains the point just above its surface, its drape
    /// if one contains the point just below the edge or the drape's tip.
    ///
    /// Only front rects overlapping the pile's columns and the band its probe points
    /// span are tested, each only against the columns it covers horizontally, and the
    /// whole check is skipped when those rects and the snow are unchanged.
    func updateVisibility(front: ArraySlice<CGRect>) {
        let n = h.count
        let x0 = frame.minX
        // Column centres run from x0 + w/2 to x0 + (n - 0.5) w.
        let cxMin = x0 + bucketW / 2, cxMax = x0 + (CGFloat(n) - 0.5) * bucketW
        var relevant = front.filter { $0.minX <= cxMax && $0.maxX > cxMin }
        if !relevant.isEmpty {
            // Vertical band of all probe points (see below).
            var lo = CGFloat.infinity, hi = -CGFloat.infinity
            for b in 0..<n {
                lo = min(lo, base[b] - h[b] - 1)
                hi = max(hi, base[b] + max(drape[b], 1))
            }
            let yLo = frame.minY + lo, yHi = frame.minY + hi
            relevant.removeAll { $0.maxY <= yLo || $0.minY > yHi }
        }
        if let last = visibilityInput, last.front == relevant,
           relevant.isEmpty || last.snowVersion == snowVersion { return }
        visibilityInput = (relevant, snowVersion)

        var vis = [Bool](repeating: true, count: n)
        var dvis = [Bool](repeating: true, count: n)
        for r in relevant {
            // Columns whose centre may lie in [r.minX, r.maxX), one column of slack
            // each side; the exact test below decides.
            let first = max(0, Int(floor((r.minX - x0) / bucketW - 0.5)) - 1)
            let last = min(n, Int(ceil((r.maxX - x0) / bucketW - 0.5)) + 1)
            guard first < last else { continue }
            for b in first..<last {
                let x = x0 + (CGFloat(b) + 0.5) * bucketW
                if vis[b], r.contains(CGPoint(x: x, y: top(b) - 1)) { vis[b] = false }
                if dvis[b] {
                    let edge = frame.minY + base[b]
                    if r.contains(CGPoint(x: x, y: edge + 1))
                        || r.contains(CGPoint(x: x, y: edge + max(drape[b], 1))) { dvis[b] = false }
                }
            }
        }
        if vis != visible { visible = vis }
        if dvis != drapeVisible { drapeVisible = dvis }
    }
}
