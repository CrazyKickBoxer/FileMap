import CoreGraphics
import Foundation
import Testing
@testable import FileMap

/// Frame-building cost on the 1M-node stress tree (the CPU part of each frame).
@Suite("Render benchmark")
struct RenderBenchmarkTests {
    @Test("Scene builder stays within a 120 fps budget on 1,111,111 boxes")
    func millionNodes() throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        let scene = DebugTree.makeScene(fanout: 10, depth: 6)
        let layoutSeconds = CFAbsoluteTimeGetCurrent() - t0
        #expect(scene.nodes.count == 1_111_111)
        let size = CGSize(width: 1728, height: 1080)
        let cameras: [(String, Camera)] = [
            ("fit all", Camera.fit(scene.bounds, in: size)),
            ("far", Camera(center: CGPoint(x: scene.bounds.midX, y: scene.bounds.midY), scale: 0.01)),
            ("mid", Camera(center: CGPoint(x: scene.bounds.midX, y: scene.bounds.midY), scale: 0.5)),
            ("near", Camera(center: CGPoint(x: scene.bounds.maxX - 300, y: scene.bounds.midY), scale: 1.2)),
        ]
        var report: [String] = ["layout \(String(format: "%.2f", layoutSeconds)) s"]
        for (name, camera) in cameras {
            var best = Double.infinity
            var boxes = 0
            for _ in 0..<20 {
                let s = CFAbsoluteTimeGetCurrent()
                let frame = SceneBuilder.build(scene: scene, camera: camera, viewSize: size, state: RenderState(), time: Date())
                best = min(best, CFAbsoluteTimeGetCurrent() - s)
                boxes = frame.boxes.count + frame.bands.count
            }
            report.append("\(name): \(String(format: "%.2f", best * 1000)) ms, \(boxes) items")
            #expect(best < 1.0 / 120, "\(name) took \(best * 1000) ms")
        }
        print("BENCH " + report.joined(separator: " | "))
    }
}
