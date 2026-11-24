import AppKit
import SwiftUI

/// Native controls keep first-click handling and window dragging separate.
struct AssistantTitleBar: NSViewRepresentable {
    var subtitle: String
    var busy: Bool
    var settings: () -> Void
    var newChat: () -> Void
    var collapse: () -> Void

    func makeNSView(context: Context) -> AssistantTitleBarView { AssistantTitleBarView() }
    func updateNSView(_ view: AssistantTitleBarView, context: Context) {
        view.dragArea.subtitle.stringValue = subtitle
        view.settingsButton.isEnabled = !busy
        view.settings = settings; view.newChat = newChat; view.collapse = collapse
    }
}

final class AssistantTitleBarView: NSView {
    let dragArea = AssistantDragArea()
    let settingsButton = AssistantTitleButton(symbol: "gearshape", label: "AI 模型设置")
    let newChatButton = AssistantTitleButton(symbol: "square.and.pencil", label: "新对话")
    let collapseButton = AssistantTitleButton(symbol: "minus", label: "收起为悬浮图标")
    var settings: (() -> Void)?
    var newChat: (() -> Void)?
    var collapse: (() -> Void)?

    init() {
        super.init(frame: .zero)
        for view in [dragArea, settingsButton, newChatButton, collapseButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for button in [settingsButton, newChatButton, collapseButton] {
            button.target = self
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 36),
                button.heightAnchor.constraint(equalToConstant: 36),
                button.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
        settingsButton.action = #selector(openSettings)
        newChatButton.action = #selector(startConversation)
        collapseButton.action = #selector(collapseConversation)
        NSLayoutConstraint.activate([
            dragArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragArea.topAnchor.constraint(equalTo: topAnchor),
            dragArea.bottomAnchor.constraint(equalTo: bottomAnchor),
            dragArea.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -8),
            settingsButton.trailingAnchor.constraint(equalTo: newChatButton.leadingAnchor, constant: -6),
            newChatButton.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -6),
            collapseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    @objc private func openSettings() { settings?() }
    @objc private func startConversation() { newChat?() }
    @objc private func collapseConversation() { collapse?() }
}

final class AssistantTitleButton: NSButton {
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        title = ""; isBordered = false; imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        contentTintColor = NSColor(Theme.ink)
        wantsLayer = true; layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(Theme.pale).cgColor
        toolTip = label; setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    // Borderless toolbar buttons must use their full visible rectangle for layout and hit testing.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AssistantDragArea: NSView {
    let subtitle = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!)
        icon.contentTintColor = NSColor(Theme.accent)
        let title = NSTextField(labelWithString: "清风 AI")
        title.font = .systemFont(ofSize: 15, weight: .semibold); title.textColor = NSColor(Theme.ink)
        subtitle.font = .systemFont(ofSize: 10); subtitle.textColor = NSColor(Theme.muted)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, title, subtitle] {
            view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
        toolTip = "拖动标题栏移动对话框"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
