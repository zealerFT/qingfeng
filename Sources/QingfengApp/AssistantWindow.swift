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
            guard let self else { return }
            for panel in [self.bubble, self.conversation].compactMap({ $0 }) {
                panel.setFrameOrigin(self.visibleOrigin(panel.frame.origin, size: panel.frame.size))
            }
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
        button.didDrag = { [weak self, weak panel] in
            guard let self, let panel else { return }
            // Clamp only after the native drag ends, allowing free movement across windows/displays.
            panel.setFrameOrigin(self.visibleOrigin(panel.frame.origin, size: size))
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: self.positionKey)
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
            panel.contentView = AssistantHostingView(rootView: AssistantView(model: model, collapse: { [weak self] in self?.collapse() }))
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

final class FloatingAssistantButton: NSView {
    var open: (() -> Void)?
    var hide: (() -> Void)?
    var didDrag: (() -> Void)?
    private var mouseStart = NSPoint.zero
    private var mouseDownEvent: NSEvent?
    private var dragged = false
    private var dragCompletionPending = false
    private var dragEndTimer: Timer?
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
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        finishDrag()
        mouseDownEvent = event
        mouseStart = event.locationInWindow; dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let window, let mouseDownEvent else { return }
        let current = event.locationInWindow
        let dx = current.x - mouseStart.x, dy = current.y - mouseStart.y
        guard hypot(dx, dy) > 4 else { return }
        dragged = true
        dragCompletionPending = true
        // AppKit requires the original mouse-down event, returns immediately, and may consume mouse-up.
        window.performDrag(with: mouseDownEvent)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if NSEvent.pressedMouseButtons & 1 == 0 { self.finishDrag() }
        }
        dragEndTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func finishDrag() {
        dragEndTimer?.invalidate(); dragEndTimer = nil
        guard dragCompletionPending else { return }
        dragCompletionPending = false
        didDrag?()
    }
    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        if dragged { finishDrag() } else { open?() }
    }
    deinit { dragEndTimer?.invalidate() }
    override func accessibilityPerformPress() -> Bool { open?(); return true }
    @objc private func showChat() { open?() }
    @objc private func hideBubble() { hide?() }
}
