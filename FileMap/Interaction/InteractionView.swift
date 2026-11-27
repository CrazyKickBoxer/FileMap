import AppKit
import Quartz
import SwiftUI

/// Transparent AppKit view over the map that owns all input: trackpad and mouse, keyboard,
/// drag and drop, Quick Look, and the context menu.
final class InteractionView: NSView {
    let model: MapModel
    var actions: MapActions { MapActions(model: model) }

    enum Press {
        case none
        case pan(last: CGPoint, moved: Bool)
        case marquee(start: CGPoint, extend: Bool)
        case node(key: SceneKey, start: CGPoint, wasSelected: Bool, onTitle: Bool, modifiers: NSEvent.ModifierFlags, event: NSEvent)
        case dragging
    }

    var press: Press = .none
    var renameTimer: Timer?
    var springTimer: Timer?
    var springKey: SceneKey?
    var quickLookURLs: [URL] = []

    init(model: MapModel) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.group)
        setAccessibilityLabel("File map")
        model.quickLookHandler = { [weak self] in self?.toggleQuickLook() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var undoManager: UndoManager? { model.undoManager }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if model.viewSize != newSize { model.viewSize = newSize }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        model.viewSize = bounds.size
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    // MARK: Trackpad and wheel

    override func scrollWheel(with event: NSEvent) {
        let p = point(event)
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
            // Mouse wheel (or ⌘-scroll): zoom toward the cursor.
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
            let factor = exp(delta)
            model.moveCamera { $0.zoom(by: factor, around: p, in: bounds.size) }
        } else {
            model.moveCamera { $0.pan(byScreen: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)) }
        }
    }

    override func magnify(with event: NSEvent) {
        let p = point(event)
        model.moveCamera { $0.zoom(by: 1 + event.magnification, around: p, in: bounds.size) }
    }

    override func smartMagnify(with event: NSEvent) {
        if let key = model.hitTest(screen: point(event)) { model.select(key) }
        model.fitSelection()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        renameTimer?.invalidate()
        model.moreGridParent = nil
        let p = point(event)
        let key = model.hitTest(screen: p)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.clickCount >= 2, let key {
            model.select(key)
            press = .none
            Task { await actions.open() }
            return
        }
        guard let key else {
            press = flags.contains(.shift) || flags.contains(.command) ? .marquee(start: p, extend: true) : .pan(last: p, moved: false)
            return
        }
        let wasSelected = model.selection.contains(key)
        if flags.contains(.command) {
            model.select(key, mode: .toggle)
        } else if flags.contains(.shift) {
            model.select(key, mode: .extend)
        } else if !wasSelected {
            model.select(key)
        } else {
            model.setFocus(key)
        }
        let onTitle = wasSelected && model.selection.count == 1 && model.isOnTitle(key, screen: p)
        press = .node(key: key, start: p, wasSelected: wasSelected, onTitle: onTitle, modifiers: flags, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch press {
        case let .pan(last, _):
            model.moveCamera { $0.pan(byScreen: CGSize(width: p.x - last.x, height: p.y - last.y)) }
            press = .pan(last: p, moved: true)
        case let .marquee(start, extend):
            let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            model.marquee = rect
            model.selectBoxes(inScreenRect: rect, extend: extend)
        case let .node(key, start, _, _, _, downEvent):
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            if case .node = key, !model.selectedNodes.isEmpty {
                press = .dragging
                beginFileDrag(event: downEvent)
            } else {
                press = .pan(last: p, moved: true)
            }
        case .none, .dragging:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = .none }
        switch press {
        case let .pan(_, moved):
            if !moved { model.select(nil) }
        case .marquee:
            model.marquee = nil
        case let .node(key, _, wasSelected, onTitle, modifiers, _):
            if modifiers.contains(.command) || modifiers.contains(.shift) { return }
            if model.selection.count > 1 { model.select(key) }
            if onTitle, key.nodeID != nil {
                renameTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval + 0.05, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model.beginRename() }
                }
                return
            }
            Task { await model.activate(key, wasSelected: wasSelected) }
        case .none, .dragging:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        if let key = model.hitTest(screen: p), !model.selection.contains(key) { model.select(key) }
        NSMenu.popUpContextMenu(actions.contextMenu(), with: event, for: self)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case 123: Task { await model.moveSelection(.left) }
        case 124: Task { await model.moveSelection(.right) }
        case 125: Task { await model.moveSelection(.down) }
        case 126:
            if flags.contains(.command) { model.goToParent() } else { Task { await model.moveSelection(.up) } }
        case 36, 76: Task { await actions.open() }
        case 49: toggleQuickLook()
        case 120: actions.rename()
        case 51, 117:
            if flags.contains(.command) { actions.trash() } else { super.keyDown(with: event) }
        case 53:
            if model.moreGridParent != nil { model.moreGridParent = nil } else { model.select(nil) }
        default:
            super.keyDown(with: event)
        }
    }

    // Standard Edit menu actions arrive through the responder chain.
    @objc func copy(_ sender: Any?) { actions.copy() }
    @objc func paste(_ sender: Any?) { actions.paste() }
    @objc override func selectAll(_ sender: Any?) { model.selectAll() }
    @objc func delete(_ sender: Any?) { actions.trash() }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityChildren() -> [Any]? {
        model.frameSink.last.boxes.prefix(400).map { box in
            let element = MapBoxElement(key: box.key, model: model)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(box.display.accessibilityLabel)
            element.setAccessibilityFrameInParentSpace(box.rect)
            element.setAccessibilityParent(self)
            element.setAccessibilitySelected(box.selected)
            return element
        }
    }
}

/// One box exposed to VoiceOver. Pressing it selects (and expands) the box.
final class MapBoxElement: NSAccessibilityElement {
    let key: SceneKey
    weak var model: MapModel?

    init(key: SceneKey, model: MapModel) {
        self.key = key
        self.model = model
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        let key = self.key
        nonisolated(unsafe) let model = self.model
        return MainActor.assumeIsolated {
            guard let model else { return false }
            let wasSelected = model.selection.contains(key)
            model.select(key)
            Task { await model.activate(key, wasSelected: wasSelected) }
            return true
        }
    }
}

/// Hosts `InteractionView` in SwiftUI.
struct InteractionLayer: NSViewRepresentable {
    let model: MapModel

    func makeNSView(context: Context) -> InteractionView { InteractionView(model: model) }
    func updateNSView(_ nsView: InteractionView, context: Context) {}
}
