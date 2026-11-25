import AppKit
import SwiftUI

final class AssistantHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Both assistant states are ordinary subviews of the main window.
struct AssistantBubbleLayer: NSViewRepresentable {
    @ObservedObject var model: AssistantModel

    func makeNSView(context: Context) -> AssistantBubbleContainer {
        AssistantBubbleContainer(model: model)
    }
    func updateNSView(_ view: AssistantBubbleContainer, context: Context) {
        view.updateVisibility()
    }
}

final class AssistantBubbleContainer: NSView {
    let bubble = FloatingAssistantButton(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    let conversation: AssistantHostingView<AssistantView>
    private let model: AssistantModel
    private var positioned = false
    private var conversationPositioned = false
    private var dragOrigin = NSPoint.zero
    private let positionKey = "Qingfeng.aiBubbleInWindowOrigin"
    private let conversationPositionKey = "Qingfeng.aiConversationInWindowOrigin"

    init(model: AssistantModel) {
        self.model = model
        conversation = AssistantHostingView(rootView: AssistantView(model: model, collapse: {}))
        super.init(frame: .zero)
        conversation.sizingOptions = []
        conversation.rootView = AssistantView(model: model, collapse: { [weak self] in self?.collapse() },
            beginDrag: { [weak self] in self?.dragOrigin = self?.conversation.frame.origin ?? .zero },
            drag: { [weak self] delta in self?.moveConversation(delta) },
            endDrag: { [weak self] in self?.saveConversationPosition() })
        addSubview(bubble)
        addSubview(conversation)
        bubble.didDrag = { [weak self] in self?.savePosition() }
        bubble.open = { [weak model] in model?.conversationVisible = true }
        bubble.hide = { [weak model] in model?.floatingIconEnabled = false }
        updateVisibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    func updateVisibility() {
        bubble.isHidden = !model.floatingIconEnabled || model.conversationVisible
        conversation.isHidden = !model.conversationVisible
        needsLayout = true
    }
    func collapse() {
        model.conversationVisible = false
        model.floatingIconEnabled = true
        updateVisibility()
        window?.makeFirstResponder(nil)
    }
    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if !positioned {
            let saved = model.isPreview ? nil : UserDefaults.standard.string(forKey: positionKey).map(NSPointFromString)
            bubble.setFrameOrigin(saved ?? NSPoint(x: bounds.maxX - 88, y: bounds.minY + 24))
            positioned = true
        }
        bubble.constrainToSuperview()
        if !conversationPositioned {
            let saved = model.isPreview ? nil : UserDefaults.standard.string(forKey: conversationPositionKey).map(NSPointFromString)
            conversation.setFrameOrigin(saved ?? NSPoint(x: bounds.maxX - 504, y: bounds.minY + 24))
            conversationPositioned = true
        }
        constrainConversation()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        if positioned { bubble.constrainToSuperview() }
        if conversationPositioned { constrainConversation() }
    }
    private func constrainConversation() {
        let inset: CGFloat = 8
        let size = NSSize(width: min(480, max(0, bounds.width - inset * 2)),
                          height: min(650, max(0, bounds.height - inset * 2)))
        let origin = NSPoint(
            x: max(bounds.minX + inset, min(conversation.frame.minX, bounds.maxX - size.width - inset)),
            y: max(bounds.minY + inset, min(conversation.frame.minY, bounds.maxY - size.height - inset)))
        conversation.frame = NSRect(origin: origin, size: size)
    }
    private func moveConversation(_ delta: NSPoint) {
        conversation.setFrameOrigin(NSPoint(x: dragOrigin.x + delta.x, y: dragOrigin.y + delta.y))
        constrainConversation()
    }
    private func savePosition() {
        if !model.isPreview { UserDefaults.standard.set(NSStringFromPoint(bubble.frame.origin), forKey: positionKey) }
    }
    private func saveConversationPosition() {
        if !model.isPreview {
            UserDefaults.standard.set(NSStringFromPoint(conversation.frame.origin), forKey: conversationPositionKey)
        }
    }
}

final class FloatingAssistantButton: NSView {
    var open: (() -> Void)?
    var hide: (() -> Void)?
    var didDrag: (() -> Void)?
    private var mouseStart = NSPoint.zero
    private var originStart = NSPoint.zero
    private var dragged = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "清风 AI · 点击咨询，在清风窗口内拖动"
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("清风 AI 助手")
        let menu = NSMenu()
        let show = NSMenuItem(title: "打开 AI 助手", action: #selector(showChat), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        let hideItem = NSMenuItem(title: "隐藏悬浮图标", action: #selector(hideBubble), keyEquivalent: "")
        hideItem.target = self; menu.addItem(hideItem)
        self.menu = menu
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.13, green: 0.39, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()
        if let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 25, weight: .medium)
                .applying(.init(paletteColors: [.white]))
            image.withSymbolConfiguration(configuration)?.draw(in: NSRect(x: 19, y: 19, width: 26, height: 26))
        }
    }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        mouseStart = event.locationInWindow; originStart = frame.origin; dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let current = event.locationInWindow
        let start = superview.convert(mouseStart, from: nil)
        let end = superview.convert(current, from: nil)
        let dx = end.x - start.x, dy = end.y - start.y
        guard dragged || hypot(dx, dy) > 4 else { return }
        dragged = true
        setFrameOrigin(NSPoint(x: originStart.x + dx, y: originStart.y + dy))
        constrainToSuperview()
    }
    func constrainToSuperview() {
        guard let bounds = superview?.bounds else { return }
        let inset: CGFloat = 8
        setFrameOrigin(NSPoint(
            x: max(bounds.minX + inset, min(frame.minX, bounds.maxX - frame.width - inset)),
            y: max(bounds.minY + inset, min(frame.minY, bounds.maxY - frame.height - inset))))
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { constrainToSuperview(); didDrag?() } else { open?() }
    }
    override func accessibilityPerformPress() -> Bool { open?(); return true }
    @objc private func showChat() { open?() }
    @objc private func hideBubble() { hide?() }
}
