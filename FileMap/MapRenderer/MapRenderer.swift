import SwiftUI

/// A map drawing backend. The scene builder produces a renderer-agnostic `RenderFrame`;
/// a backend only has to draw it. To move to Metal, add an `MTKView`-based type that conforms
/// and change `ActiveMapRenderer`.
@MainActor
protocol MapRenderer {
    associatedtype Content: View
    func makeView(model: MapModel) -> Content
}

typealias ActiveMapRenderer = CanvasMapRenderer
