import CoreGraphics
import Foundation
import Testing
@testable import FileMap

@Suite("Layout")
struct LayoutTests {
    private func display(_ i: Int) -> NodeDisplay {
        NodeDisplay(role: .folder, title: "\(i)", subtitle: "", modifiedAt: nil, glyph: "", kind: .folder)
    }

    /// Random forest with varied fan-out and box heights.
    private func randomInput(seed: UInt64, count: Int) -> LayoutInput {
        var rng = SplitMix(seed: seed)
        var input = LayoutInput()
        input.add(.init(key: .debug(0), size: CGSize(width: 240, height: 54), display: display(0)), parent: nil)
        for i in 1..<count {
            let parent = Int32(rng.next() % UInt64(input.entries.count))
            let h = CGFloat(20 + rng.next() % 120)
            input.add(.init(key: .debug(Int32(i)), size: CGSize(width: 240, height: h), display: display(i)), parent: parent)
        }
        return input
    }

    private func overlaps(_ scene: MapScene) -> [(Int, Int)] {
        var bad: [(Int, Int)] = []
        let sorted = scene.nodes.indices.sorted { scene.nodes[$0].rect.minY < scene.nodes[$1].rect.minY }
        for (n, i) in sorted.enumerated() {
            let a = scene.nodes[i].rect
            for j in sorted[(n + 1)...] {
                let b = scene.nodes[j].rect
                if b.minY >= a.maxY { break }
                if a.intersects(b), a.intersection(b).width > 0.01, a.intersection(b).height > 0.01 { bad.append((i, j)) }
            }
        }
        return bad
    }

    @Test("Tidy tree never overlaps boxes", arguments: [1, 2, 3, 4, 5] as [UInt64])
    func noOverlap(seed: UInt64) {
        let scene = TidyTreeLayout.layout(randomInput(seed: seed, count: 600))
        #expect(scene.nodes.count == 600)
        #expect(overlaps(scene).isEmpty)
    }

    @Test("Children are to the right of parents and parents are centred on them")
    func structure() {
        let scene = TidyTreeLayout.layout(randomInput(seed: 9, count: 200))
        for n in scene.nodes where !n.children.isEmpty {
            let kids = n.children.map { scene.nodes[Int($0)] }
            #expect(kids.allSatisfy { $0.rect.minX > n.rect.maxX })
            let mid = (kids.first!.rect.midY + kids.last!.rect.midY) / 2
            #expect(abs(n.rect.midY - mid) < 0.5)
            #expect(kids.allSatisfy { n.bounds.contains($0.bounds) })
        }
    }

    @Test("Siblings keep their order top to bottom")
    func order() {
        let scene = TidyTreeLayout.layout(randomInput(seed: 4, count: 300))
        for n in scene.nodes where n.children.count > 1 {
            let ys = n.children.map { scene.nodes[Int($0)].rect.minY }
            #expect(ys == ys.sorted())
        }
    }

    @Test("Nested grid places children inside containers without overlap")
    func nestedGrid() {
        var input = LayoutInput()
        for c in 0..<5 {
            let ci = input.add(.init(key: .cluster("\(c)"), size: CGSize(width: 300, height: 90), display: display(c)), parent: nil)
            for g in 0..<(3 + c * 2) {
                let gi = input.add(.init(key: .group("\(c)-\(g)"), size: CGSize(width: 236, height: 64), display: display(g)), parent: ci)
                if g % 2 == 0 {
                    for f in 0..<7 {
                        input.add(.init(key: .debug(Int32(c * 1000 + g * 10 + f)), size: CGSize(width: 236, height: 38), display: display(f)), parent: gi)
                    }
                }
            }
        }
        let scene = NestedGridLayout.layout(input)
        for n in scene.nodes {
            let kids = n.children.map { scene.nodes[Int($0)].rect }
            #expect(kids.allSatisfy { n.rect.contains($0) })
            for (a, x) in kids.enumerated() {
                for y in kids[(a + 1)...] { #expect(!x.intersects(y) || x.intersection(y).isEmpty) }
            }
        }
        let roots = scene.roots.map { scene.nodes[Int($0)].rect }
        for (a, x) in roots.enumerated() { for y in roots[(a + 1)...] { #expect(!x.intersects(y)) } }
    }

    @Test("Scene builder culls branches that are off screen")
    func culling() {
        let scene = TidyTreeLayout.layout(randomInput(seed: 2, count: 2000))
        let camera = Camera(center: CGPoint(x: scene.bounds.minX + 100, y: scene.bounds.midY), scale: 1)
        let frame = SceneBuilder.build(scene: scene, camera: camera, viewSize: CGSize(width: 800, height: 600), state: RenderState(), time: Date())
        #expect(frame.boxes.count < 200)
        #expect(frame.boxes.allSatisfy { $0.rect.intersects(CGRect(x: -50, y: -50, width: 900, height: 700)) })
    }

    @Test("Camera zoom keeps the point under the cursor fixed")
    func cameraZoom() {
        var cam = Camera(center: CGPoint(x: 100, y: 50), scale: 0.5)
        let size = CGSize(width: 800, height: 600)
        let cursor = CGPoint(x: 600, y: 120)
        let before = cam.toWorld(cursor, in: size)
        cam.zoom(by: 2.5, around: cursor, in: size)
        let after = cam.toWorld(cursor, in: size)
        #expect(abs(before.x - after.x) < 0.001 && abs(before.y - after.y) < 0.001)
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
