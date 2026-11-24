import AppKit
import SwiftUI
import Combine

private final class AssistantPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AssistantWindowController: NSObject, NSWindowDelegate {
    private let model: AssistantModel
    private var bubble: NSPanel?
    private var conversation: NSPanel?
    private var observers = Set<AnyCancellable>()
    private let positionKey = "Qingfeng.aiBubbleOrigin"
    init(model: AssistantModel) {
        self.model = model
        super.init()
        model.$floatingIconEnabled.dropFirst().sink { [weak self] enabled in
            if enabled { self?.showIconIfEnabled() } else { self?.bubble?.orderOut(nil) }
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in
            guard let self, let bubble = self.bubble else { return }
            bubble.setFrameOrigin(self.visibleOrigin(bubble.frame.origin, size: bubble.frame.size))
        }.store(in: &observers)
    }
    private func setup(_ panel: NSPanel) {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.title = "清风 AI"; panel.delegate = self
    }
    private func visibleOrigin(_ point: NSPoint, size: NSSize) -> NSPoint {
        let rect = NSRect(origin: point, size: size)
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(rect) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return point }
        return NSPoint(x: max(frame.minX + 8, min(point.x, frame.maxX - size.width - 8)),
                       y: max(frame.minY + 8, min(point.y, frame.maxY - size.height - 8)))
    }
    private func makeBubble() -> NSPanel {
        let size = NSSize(width: 64, height: 64)
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let saved = UserDefaults.standard.string(forKey: positionKey).map(NSPointFromString)
        let origin = visibleOrigin(saved ?? NSPoint(x: frame.maxX - 96, y: frame.minY + 90), size: size)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setup(panel)
        let button = FloatingAssistantButton(frame: NSRect(origin: .zero, size: size))
        button.open = { [weak self] in self?.showConversation() }
        button.hide = { [weak self] in self?.model.floatingIconEnabled = false }
        button.move = { [weak self, weak panel] point in
            guard let self, let panel else { return }
            panel.setFrameOrigin(self.visibleOrigin(point, size: size))
        }
        panel.contentView = button
        return panel
    }
    func showIconIfEnabled() {
        guard model.floatingIconEnabled, conversation?.isVisible != true else { return }
        if bubble == nil { bubble = makeBubble() }
        bubble?.orderFrontRegardless()
    }
    func showConversation() {
        if conversation == nil {
            let size = NSSize(width: 480, height: 650)
            let origin = visibleOrigin(bubble?.frame.origin ?? NSPoint(x: 600, y: 120), size: size)
            let panel = AssistantPanel(contentRect: NSRect(origin: origin, size: size),
                                       styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            setup(panel); panel.minSize = NSSize(width: 420, height: 480)
            panel.isMovableByWindowBackground = true
            panel.contentView = NSHostingView(rootView: AssistantView(model: model, collapse: { [weak self] in self?.collapse() }))
            conversation = panel
        }
        if let bubble, let conversation, bubble.isVisible {
            conversation.setFrameOrigin(visibleOrigin(bubble.frame.origin, size: conversation.frame.size))
        }
        bubble?.orderOut(nil)
        conversation?.makeKeyAndOrderFront(nil)
    }
    func collapse() {
        conversation?.orderOut(nil)
        model.floatingIconEnabled = true
        showIconIfEnabled()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { collapse(); return false }
    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === bubble {
            UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: positionKey)
        }
    }
}

private final class FloatingAssistantButton: NSView {
    var open: (() -> Void)?
    var hide: (() -> Void)?
    var move: ((NSPoint) -> Void)?
    private var mouseStart = NSPoint.zero
    private var windowStart = NSPoint.zero
    private var dragged = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "清风 AI · 点击咨询，拖动调整位置"
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
    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation; windowStart = window?.frame.origin ?? .zero; dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = current.x - mouseStart.x, dy = current.y - mouseStart.y
        if abs(dx) + abs(dy) > 4 { dragged = true }
        if dragged { move?(NSPoint(x: windowStart.x + dx, y: windowStart.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) { if !dragged { open?() } }
    override func accessibilityPerformPress() -> Bool { open?(); return true }
    @objc private func showChat() { open?() }
    @objc private func hideBubble() { hide?() }
}
