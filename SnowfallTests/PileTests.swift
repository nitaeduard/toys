import CoreGraphics
import Testing

/// Tests for the snow height map. Pile.swift is compiled straight into this
/// bundle, so the tests don't need to launch the Snowfall app as a test host.
struct PileTests {
    private func surface(x: CGFloat = 100, width: CGFloat = 300, radius: CGFloat = 0,
                         depth: CGFloat = 16, maxDrape: CGFloat = 36,
                         profile: [CGFloat?]? = nil) -> Surface {
        Surface(key: "test", rect: CGRect(x: x, y: 200, width: width, height: 200),
                radius: radius, depth: depth, maxDrape: maxDrape, profile: profile)
    }

    @Test func oneColumnPerBucket() {
        let pile = Pile(surface(width: 300))
        #expect(pile.h.count == Int(300 / bucketW))
        #expect(pile.h.allSatisfy { $0 == 0 })
        #expect(pile.drape.allSatisfy { $0 == 0 })
    }

    @Test func flatSurfaceIsFlatAndSolidEverywhere() {
        let pile = Pile(surface(radius: 0))
        #expect(pile.base.allSatisfy { $0 == 0 })
        #expect(pile.solid.allSatisfy { $0 })
        #expect(pile.flat.allSatisfy { $0 })
    }

    @Test func capIsLumpyAroundTheConfiguredDepth() {
        let pile = Pile(surface(radius: 0, depth: 16))
        // noise is 0...1, so the cap is depth * 0.75...1.25
        #expect(pile.capH.allSatisfy { $0 >= 16 * 0.75 - 0.001 && $0 <= 16 * 1.25 + 0.001 })
        #expect(Set(pile.capH).count > 1, "a full pile should not be a flat line")
    }

    @Test func roundedCornersDipAndHoldLessSnow() {
        let pile = Pile(surface(width: 300, radius: 16))
        let mid = pile.h.count / 2
        #expect(pile.base[0] > 0)
        #expect(pile.base[pile.base.count - 1] > 0)
        #expect(pile.base[mid] == 0)
        #expect(pile.capH[0] < pile.capH[mid])
        #expect(!pile.flat[0], "the steep corner is not flat enough to drape from")
        #expect(pile.flat[mid])
    }

    @Test func radiusIsClampedToHalfTheSize() {
        let pile = Pile(surface(width: 30, radius: 1000))
        // A 30 pt wide surface can't have more than a 15 pt corner radius.
        #expect(pile.base.allSatisfy { $0 <= 15 })
    }

    @Test func topIsMeasuredFromTheFrame() {
        let pile = Pile(surface(radius: 16))
        pile.h[0] = 3
        #expect(pile.top(0) == pile.frame.minY + pile.base[0] - 3)
    }

    @Test func addingBelowTheCapJustGrowsTheColumn() {
        let pile = Pile(surface())
        let mid = pile.h.count / 2
        #expect(pile.add(at: mid, 1) == nil)
        #expect(pile.h[mid] == 1)
        #expect(pile.drape[mid] == 0)
    }

    @Test func snowSlidesOffAHigherColumn() {
        let pile = Pile(surface())
        let mid = pile.h.count / 2
        pile.h[mid] = 5
        _ = pile.add(at: mid, 0.5)
        #expect(pile.h[mid] == 5, "snow landing on a peak slides to a lower neighbour")
        #expect(pile.h[mid - 1] + pile.h[mid + 1] == 0.5)
    }

    @Test func columnsNeverExceedTheirCap() {
        let pile = Pile(surface(width: 60, radius: 16))
        for i in 0..<5000 { _ = pile.add(at: i % pile.h.count, 0.7) }
        for i in pile.h.indices { #expect(pile.h[i] <= pile.capH[i] + 0.0001) }
    }

    @Test func overflowOnAFlatTopDrapesAndEventuallyBreaks() {
        let pile = Pile(surface(width: 30, radius: 0, maxDrape: 20))
        let mid = pile.h.count / 2
        var broke: Int?
        for _ in 0..<10_000 {
            broke = pile.add(at: mid, 1)
            if broke != nil { break }
        }
        let j = try! #require(broke)
        #expect(pile.drape[j] > pile.breakAt[j])
        #expect(pile.drape.contains { $0 > 0 })
    }

    @Test func noDrapeWhenTheSurfaceDoesNotAllowIt() {
        let pile = Pile(surface(width: 30, radius: 0, maxDrape: 0))
        for _ in 0..<2000 { #expect(pile.add(at: 5, 1) == nil) }
        #expect(pile.drape.allSatisfy { $0 == 0 })
        #expect(pile.breakAt.allSatisfy { $0 == 0 })
    }

    @Test func breakPointIsWithinTheDrapeRange() {
        for _ in 0..<200 {
            let b = Pile.randomBreak(36)
            #expect(b >= 36 * 0.45 && b <= 36)
        }
        #expect(Pile.randomBreak(0) == 0)
    }

    @Test func iconProfileMarksTransparentColumns() {
        // 4 columns: transparent, 10 pt down, 2 pt down, transparent
        let pile = Pile(surface(width: 4 * bucketW, profile: [nil, 10, 2, nil]))
        #expect(pile.solid == [false, true, true, false])
        #expect(pile.base[1] == 10)
        #expect(pile.base[2] == 2)
        #expect(pile.capH[0] == 0 && pile.capH[3] == 0)
        #expect(pile.base[0] == pile.frame.height, "nothing to land on: the base is the bottom")
    }

    @Test func shortProfileIsPaddedWithTransparentColumns() {
        let pile = Pile(surface(width: 4 * bucketW, profile: [0, 0]))
        #expect(pile.solid == [true, true, false, false])
    }

    @Test func transferKeepsSnowAtTheSameScreenPosition() {
        let old = Pile(surface(x: 100, width: 300))
        for i in old.h.indices { old.h[i] = min(old.capH[i], CGFloat(i % 7)) }
        // The Dock grew by two columns on the left.
        let new = Pile(surface(x: 100 - 2 * bucketW, width: 300 + 2 * bucketW))
        new.transfer(from: old)
        #expect(new.h[0] == 0 && new.h[1] == 0)
        for i in old.h.indices {
            #expect(new.h[i + 2] == min(new.capH[i + 2], old.h[i]))
        }
    }
}

/// `Pile.updateVisibility` must match the straightforward per-column check.
struct VisibilityTests {
    /// The original check: every column against every rect in front.
    private func reference(_ pile: Pile, front: [CGRect]) -> (visible: [Bool], drape: [Bool]) {
        var vis: [Bool] = [], dvis: [Bool] = []
        for b in pile.h.indices {
            let x = pile.frame.minX + (CGFloat(b) + 0.5) * bucketW
            let p = CGPoint(x: x, y: pile.top(b) - 1)
            vis.append(!front.contains { $0.contains(p) })
            let edge = pile.frame.minY + pile.base[b]
            let q1 = CGPoint(x: x, y: edge + 1), q2 = CGPoint(x: x, y: edge + max(pile.drape[b], 1))
            dvis.append(!front.contains { $0.contains(q1) || $0.contains(q2) })
        }
        return (vis, dvis)
    }

    private func snowyPile() -> Pile {
        let pile = Pile(Surface(key: "p", rect: CGRect(x: 100.4, y: 300.7, width: 400, height: 300),
                                radius: 16, depth: 16, maxDrape: 36))
        for i in pile.h.indices {
            pile.h[i] = pile.capH[i] * CGFloat(i % 5) / 4
            if pile.flat[i] { pile.drape[i] = CGFloat((i * 7) % 30) }
        }
        return pile
    }

    @Test func nothingInFrontLeavesEverythingVisible() {
        let pile = snowyPile()
        pile.visible = pile.visible.map { _ in false }
        pile.updateVisibility(front: [CGRect(x: 0, y: 0, width: 50, height: 50)][...])
        #expect(pile.visible.allSatisfy { $0 })
        #expect(pile.drapeVisible.allSatisfy { $0 })
    }

    @Test func coveredRangeIsHidden() {
        let pile = snowyPile()
        // A window whose top edge sits inside the pile band, over columns ~33...66.
        let front = CGRect(x: 200, y: 290, width: 100, height: 400)
        pile.updateVisibility(front: [front][...])
        let expected = reference(pile, front: [front])
        #expect(pile.visible == expected.visible)
        #expect(pile.drapeVisible == expected.drape)
        #expect(pile.visible.contains(false) && pile.visible.contains(true))
    }

    @Test func matchesTheReferenceForRandomRects() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let pile = snowyPile()
            let front = (0..<Int.random(in: 0...6, using: &rng)).map { _ in
                CGRect(x: .random(in: 0...600, using: &rng), y: .random(in: 250...360, using: &rng),
                       width: .random(in: 1...300, using: &rng), height: .random(in: 1...120, using: &rng))
            }
            pile.updateVisibility(front: front[...])
            let expected = reference(pile, front: front)
            #expect(pile.visible == expected.visible)
            #expect(pile.drapeVisible == expected.drape)
        }
    }

    @Test func recomputesWhenTheSnowChangesAndSkipsWhenNot() {
        let pile = snowyPile()
        let front = [CGRect(x: 200, y: 280, width: 100, height: 400)]
        pile.updateVisibility(front: front[...])
        let v = pile.visibilityVersion
        pile.updateVisibility(front: front[...])
        #expect(pile.visibilityVersion == v, "same input: nothing rewritten")

        // Snow grows above the window's top edge: those columns become visible.
        for i in pile.h.indices { pile.h[i] = pile.capH[i] }
        pile.updateVisibility(front: front[...])
        let expected = reference(pile, front: front)
        #expect(pile.visible == expected.visible)
        #expect(pile.drapeVisible == expected.drape)
    }

    @Test func versionsTrackChanges() {
        let pile = snowyPile()
        let s = pile.snowVersion
        _ = pile.add(at: pile.h.count / 2, 0.1)
        #expect(pile.snowVersion != s)
        let v = pile.visibilityVersion
        pile.visible[3] = false
        #expect(pile.visibilityVersion != v)
    }
}

/// Falling snow landing on piles, and how full a pile looks.
struct FallingSnowTests {
    private func pile(width: CGFloat = 60, depth: CGFloat = 16) -> Pile {
        Pile(Surface(key: "t", rect: CGRect(x: 0, y: 100, width: width, height: 100),
                     radius: 0, depth: depth, maxDrape: 0))
    }

    @Test func bareSurfaceCatchesMostClumps() {
        let p = pile()
        #expect(p.catchChance(at: 3) > 0.8)
    }

    @Test func fullColumnLetsMostClumpsTumbleOn() {
        let p = pile()
        p.h[3] = p.capH[3]
        #expect(p.catchChance(at: 3) < 0.1)
        #expect(p.catchChance(at: 3) > 0, "a little still sticks")
    }

    @Test func catchChanceFallsAsSnowBuildsUp() {
        let p = pile()
        var last = CGFloat.infinity
        for f in stride(from: 0.0, through: 1.0, by: 0.1) {
            p.h[3] = p.capH[3] * f
            let c = p.catchChance(at: 3)
            #expect(c < last)
            last = c
        }
    }

    @Test func transparentColumnsCatchNothing() {
        let p = Pile(Surface(key: "i", rect: CGRect(x: 0, y: 0, width: 4 * bucketW, height: 40),
                             radius: 0, depth: 7, maxDrape: 0, profile: [nil, 3, 3, nil]))
        #expect(p.catchChance(at: 0) == 0)
        #expect(p.catchChance(at: 1) > 0)
    }

    @Test func maxDepthIsTheDeepestColumn() {
        let p = pile(width: 60)
        #expect(p.maxDepth == 0)
        p.h[4] = 7; p.h[9] = 3
        #expect(p.maxDepth == 7)
    }

    @Test func coveredFractionCountsColumnsWithSnow() {
        let p = pile(width: 60)          // 20 columns
        #expect(p.coveredFraction() == 0)
        for i in 0..<15 { p.h[i] = 2 }
        p.h[15] = 0.5                     // a dusting doesn't count
        #expect(p.coveredFraction() == 0.75)
    }

    @Test func coveredFractionIgnoresTransparentColumns() {
        let p = Pile(Surface(key: "i", rect: CGRect(x: 0, y: 0, width: 4 * bucketW, height: 40),
                             radius: 0, depth: 7, maxDrape: 0, profile: [nil, 3, 3, nil]))
        p.h[1] = 2
        #expect(p.coveredFraction() == 0.5)
    }

    @Test func columnsBetweenTwoXs() {
        let p = pile(width: 60)          // column k is centred at 1.5 + 3k
        #expect(p.columns(from: 0, to: 6) == 0..<2)
        #expect(p.columns(from: 1.5, to: 1.6) == 0..<1)
        #expect(p.columns(from: 1.6, to: 4.4) == 0..<0)
        #expect(p.columns(from: -50, to: 500) == 0..<20)
        #expect(p.columns(from: 70, to: 90).isEmpty)
    }

    @Test func clumpSnowMatchesHowPilesBreakUp() {
        #expect(clumpSnow(2) == 3.2)
        #expect(Clump(p: .zero, v: .zero, r: 2).lands)
    }
}

/// Old snow packing into ice, and melt water growing icicles.
struct IceTests {
    private func pile(width: CGFloat = 300, radius: CGFloat = 16, maxDrape: CGFloat = 36) -> Pile {
        Pile(Surface(key: "w1", rect: CGRect(x: 100, y: 200, width: width, height: 200),
                     radius: radius, depth: 16, maxDrape: maxDrape))
    }

    private func age(_ p: Pile, seconds: CGFloat) {
        var t: CGFloat = 0
        while t < seconds { p.freeze(dt: 2); t += 2 }
    }

    @Test func freshSnowIsNotIce() {
        let p = pile()
        p.h[50] = 10
        age(p, seconds: Pile.iceStart - 4)
        #expect(p.ice[50] == 0)
    }

    @Test func oldSnowTurnsToIceFromTheBottom() {
        let p = pile()
        p.h[50] = 10
        age(p, seconds: Pile.iceStart + 60)
        #expect(p.ice[50] > 0)
        #expect(p.ice[50] < 10)
        age(p, seconds: 540)              // ~10 minutes after it settled
        #expect(p.ice[50] > 8, "mostly ice by then")
        #expect(p.ice[50] <= p.h[50])
    }

    @Test func emptyColumnsDoNotFreeze() {
        let p = pile()
        age(p, seconds: 600)
        #expect(p.ice.allSatisfy { $0 == 0 })
    }

    @Test func clearingAColumnStartsItOver() {
        let p = pile()
        p.h[50] = 10
        age(p, seconds: 400)
        #expect(p.ice[50] > 0)
        p.h[50] = 0
        p.freeze(dt: 2)
        #expect(p.ice[50] == 0)
        p.h[50] = 10
        age(p, seconds: 60)
        #expect(p.ice[50] == 0, "fresh snow on a cleared column starts as snow again")
    }

    @Test func iceNeverShowsAboveTheSnow() {
        let p = pile()
        p.h[50] = 10
        age(p, seconds: 600)
        p.h[50] = 3                       // the top was knocked off
        #expect(p.iceDepth(50) == 3)
        p.freeze(dt: 2)
        #expect(p.ice[50] <= 3)
    }

    @Test func freezingChangesIceInCoarseSteps() {
        let p = pile()
        p.h[50] = 10
        age(p, seconds: Pile.iceStart + 2)
        let v = p.snowVersion
        p.freeze(dt: 0.01)               // far less than a 0.5 pt step
        #expect(p.snowVersion == v, "tiny changes must not make the renderer redraw")
    }

    @Test func transferKeepsTheIce() {
        let old = pile()
        old.h[50] = 10
        age(old, seconds: 600)
        let new = Pile(Surface(key: "dock", rect: old.frame, radius: 16, depth: 16, maxDrape: 36))
        new.transfer(from: old)
        #expect(new.ice[50] == min(new.h[50], old.ice[50]))
    }

    @Test func meltWaterGrowsIciclesAtThatCorner() {
        let p = pile()
        #expect(p.icicles().isEmpty)
        for _ in 0..<40 { p.addWater(side: 0, 0.7) }
        #expect(p.icicleLength[0] > 0)
        #expect(p.icicleLength[1] == 0)
        let icicles = p.icicles()
        #expect(!icicles.isEmpty)
        #expect(icicles.allSatisfy { $0.x < p.frame.midX }, "left side water hangs at the left corner")
        #expect(icicles.allSatisfy { $0.x > p.frame.minX + p.cornerRadius }, "under the flat part, past the rounded corner")
    }

    @Test func iciclesGrowSlowerAsTheyGetLongerAndStopAtTheDrapeLength() {
        let p = pile(maxDrape: 36)
        p.addWater(side: 1, 10)
        let first = p.icicleLength[1]
        p.addWater(side: 1, 10)
        let second = p.icicleLength[1] - first
        #expect(second < first)
        p.addWater(side: 1, 100_000)
        #expect(p.icicleLength[1] == 36)
        #expect(p.icicles().map(\.length).max() ?? 0 <= 36 * 1.15)
    }

    @Test func icicleLengthMovesInHalfPointSteps() {
        let p = pile()
        for _ in 0..<57 { p.addWater(side: 0, 0.37) }
        let l = p.icicleLength[0]
        #expect((l * 2).rounded() == l * 2)
    }

    @Test func noIciclesWithoutADrape() {
        let p = pile(maxDrape: 0)        // desktop icons don't have one... nor the ground
        p.addWater(side: 0, 50)
        #expect(p.icicles().isEmpty)
    }

    @Test func clearingIciclesStartsOver() {
        let p = pile()
        p.addWater(side: 0, 50)
        p.clearIcicles()
        #expect(p.icicles().isEmpty)
        p.addWater(side: 0, 0.1)
        #expect(p.icicleLength[0] < 1)
    }

    @Test func sideEnteredFromTheLeftOrRight() {
        let r = CGRect(x: 100, y: 100, width: 50, height: 50)
        #expect(sideEntered(prevX: 99, rect: r) == 0)
        #expect(sideEntered(prevX: 150, rect: r) == 1)
        #expect(sideEntered(prevX: 120, rect: r) == nil)
    }
}
