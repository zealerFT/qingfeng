import AppKit
import SwiftUI
import Combine

private final class AssistantPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum AssistantWindowPlacement {
    static func visibleOrigin(_ point: NSPoint, size: NSSize, screens: [NSRect]) -> NSPoint {
        let rect = NSRect(origin: point, size: size)
        // Prefer the destination display, not the first display touched by the icon.
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let screen = screens.first { $0.contains(center) } ?? screens.min {
            func distance(_ frame: NSRect) -> CGFloat {
                let dx = max(frame.minX - center.x, 0, center.x - frame.maxX)
                let dy = max(frame.minY - center.y, 0, center.y - frame.maxY)
                return dx * dx + dy * dy
            }
            return distance($0) < distance($1)
        }
        guard let frame = screen else { return point }
        return NSPoint(x: max(frame.minX + 8, min(point.x, frame.maxX - size.width - 8)),
                       y: max(frame.minY + 8, min(point.y, frame.maxY - size.height - 8)))
    }
}

final class AssistantHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class AssistantWindowController: NSObject, NSWindowDelegate {
    private let model: AssistantModel
    private weak var bubbleContainer: AssistantBubbleContainer?
    private var conversation: NSPanel?
    private var observers = Set<AnyCancellable>()
    init(model: AssistantModel) {
        self.model = model
        super.init()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in
            guard let self, let panel = self.conversation else { return }
            panel.setFrameOrigin(self.visibleOrigin(panel.frame.origin, size: panel.frame.size))
        }.store(in: &observers)
    }
    private func setup(_ panel: NSPanel) {
        panel.level = .floating
        // All Spaces alone does not opt a panel into other apps' Stage Manager sets/full-screen spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.title = "清风 AI"; panel.delegate = self
    }
    private func visibleOrigin(_ point: NSPoint, size: NSSize) -> NSPoint {
        AssistantWindowPlacement.visibleOrigin(point, size: size, screens: NSScreen.screens.map(\.visibleFrame))
    }
    func attach(_ container: AssistantBubbleContainer) { bubbleContainer = container }

    private var bubbleOrigin: NSPoint? {
        guard let container = bubbleContainer, let window = container.window else { return nil }
        return window.convertToScreen(container.bubble.convert(container.bubble.bounds, to: nil)).origin
    }
    func showConversation() {
        if conversation == nil {
            let size = NSSize(width: 480, height: 650)
            let origin = visibleOrigin(bubbleOrigin ?? NSPoint(x: 600, y: 120), size: size)
            let panel = AssistantPanel(contentRect: NSRect(origin: origin, size: size),
                                       styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            setup(panel); panel.minSize = NSSize(width: 420, height: 480)
            panel.contentView = AssistantHostingView(rootView: AssistantView(model: model, collapse: { [weak self] in self?.collapse() }))
            conversation = panel
        }
        if let origin = bubbleOrigin, let conversation, !model.conversationVisible {
            conversation.setFrameOrigin(visibleOrigin(origin, size: conversation.frame.size))
        }
        model.conversationVisible = true
        conversation?.makeKeyAndOrderFront(nil)
    }
    func collapse() {
        conversation?.orderOut(nil)
        model.conversationVisible = false
        model.floatingIconEnabled = true
        bubbleContainer?.window?.deminiaturize(nil)
        bubbleContainer?.window?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { collapse(); return false }
}

/// The icon is a subview of the main window, never a separately movable panel.
struct AssistantBubbleLayer: NSViewRepresentable {
    @ObservedObject var model: AssistantModel
    var attach: (AssistantBubbleContainer) -> Void
    var open: () -> Void

    func makeNSView(context: Context) -> AssistantBubbleContainer {
        AssistantBubbleContainer(preview: model.isPreview)
    }
    func updateNSView(_ view: AssistantBubbleContainer, context: Context) {
        view.bubble.isHidden = !model.floatingIconEnabled || model.conversationVisible
        view.bubble.open = open
        view.bubble.hide = { model.floatingIconEnabled = false }
        attach(view)
    }
}

final class AssistantBubbleContainer: NSView {
    let bubble = FloatingAssistantButton(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    private let preview: Bool
    private var positioned = false
    private let positionKey = "Qingfeng.aiBubbleInWindowOrigin"

    init(preview: Bool) {
        self.preview = preview
        super.init(frame: .zero)
        addSubview(bubble)
        bubble.didDrag = { [weak self] in self?.savePosition() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if !positioned {
            let saved = preview ? nil : UserDefaults.standard.string(forKey: positionKey).map(NSPointFromString)
            bubble.setFrameOrigin(saved ?? NSPoint(x: bounds.maxX - 88, y: bounds.minY + 24))
            positioned = true
        }
        bubble.constrainToSuperview()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        if positioned { bubble.constrainToSuperview() }
    }
    private func savePosition() {
        if !preview { UserDefaults.standard.set(NSStringFromPoint(bubble.frame.origin), forKey: positionKey) }
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
