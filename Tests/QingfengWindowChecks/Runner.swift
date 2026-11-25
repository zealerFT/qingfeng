import AppKit
import SwiftUI

// Exercise AppKit hit testing and event routing without moving the real pointer,
// opening a visible window, reading user settings, or contacting a model service.
private final class DragProbePanel: NSPanel {
    var dragCount = 0
    var dragEventType: NSEvent.EventType?
    var destination = NSPoint(x: 1800, y: 400)
    override func performDrag(with event: NSEvent) {
        dragCount += 1
        dragEventType = event.type
        setFrameOrigin(destination)
    }
}

@main enum WindowChecks {
    @MainActor static func main() async throws {
        checkWindows()
        try await CredentialChecks.run()
        try await StorageChecks.run()
    }

    @MainActor static func checkWindows() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        let panel = DragProbePanel(contentRect: NSRect(x: 300, y: 300, width: 1180, height: 800),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let embeddedModel = AssistantModel(preview: true)
        embeddedModel.floatingIconEnabled = true
        let container = AssistantBubbleContainer(model: embeddedModel)
        panel.contentView = container
        container.layoutSubtreeIfNeeded()
        let bubble = container.bubble
        var opened = 0, completedDrags = 0
        bubble.open = { opened += 1 }
        bubble.didDrag = { completedDrags += 1 }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        precondition(bubble.acceptsFirstMouse(for: nil) && !bubble.mouseDownCanMoveWindow)
        bubble.mouseDown(with: event(.leftMouseDown, NSPoint(x: 32, y: 32)))
        bubble.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 33, y: 33)))
        bubble.mouseUp(with: event(.leftMouseUp, NSPoint(x: 33, y: 33)))
        precondition(opened == 1 && panel.dragCount == 0)
        let originalWindowFrame = panel.frame
        for destination in [NSPoint(x: -4000, y: 400), NSPoint(x: 4000, y: 400),
                            NSPoint(x: 500, y: -4000), NSPoint(x: 500, y: 4000)] {
            bubble.mouseDown(with: event(.leftMouseDown, NSPoint(x: 32, y: 32)))
            bubble.mouseDragged(with: event(.leftMouseDragged, destination))
            // Check during dragging, not just after mouse-up.
            precondition(container.bounds.insetBy(dx: 8, dy: 8).contains(bubble.frame))
            bubble.mouseUp(with: event(.leftMouseUp, destination))
            precondition(container.bounds.insetBy(dx: 8, dy: 8).contains(bubble.frame))
        }
        precondition(panel.dragCount == 0 && completedDrags == 4 && opened == 1)
        precondition(panel.frame == originalWindowFrame)
        panel.setContentSize(NSSize(width: 700, height: 500))
        container.layoutSubtreeIfNeeded()
        precondition(container.bounds.contains(bubble.frame))
        let localOrigin = bubble.frame.origin
        panel.setFrameOrigin(NSPoint(x: -1500, y: 500))
        precondition(bubble.frame.origin == localOrigin && bubble.window === panel)
        precondition(container.hitTest(NSPoint(x: 200, y: 200)) == nil)
        let center = bubble.convert(NSPoint(x: 32, y: 32), to: container.superview)
        precondition(container.hitTest(center) === bubble)
        bubble.isHidden = true
        precondition(container.hitTest(center) == nil)
        bubble.isHidden = false
        bubble.mouseDown(with: event(.leftMouseDown, NSPoint(x: 32, y: 32)))
        bubble.mouseUp(with: event(.leftMouseUp, NSPoint(x: 32, y: 32)))
        precondition(opened == 2)
        print("PASS icon stays inside main window during all four edge drags, resize and window movement; background stays clickable")

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        embeddedModel.conversationVisible = true
        container.updateVisibility()
        panel.setContentSize(NSSize(width: 1180, height: 800))
        container.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        container.layoutSubtreeIfNeeded()
        let conversation = container.conversation
        guard let embeddedBar = descendants(conversation).compactMap({ $0 as? AssistantTitleBarView }).first else {
            fatalError("Missing embedded title bar")
        }
        let parentFrame = panel.frame
        for destination in [NSPoint(x: -4000, y: 400), NSPoint(x: 4000, y: 400),
                            NSPoint(x: 500, y: -4000), NSPoint(x: 500, y: 4000)] {
            embeddedBar.dragArea.mouseDown(with: event(.leftMouseDown, .zero))
            embeddedBar.dragArea.mouseDragged(with: event(.leftMouseDragged, destination))
            precondition(container.bounds.insetBy(dx: 8, dy: 8).contains(conversation.frame))
            embeddedBar.dragArea.mouseUp(with: event(.leftMouseUp, destination))
            precondition(conversation.window === panel && conversation.superview === container)
        }
        precondition(panel.dragCount == 0 && panel.frame == parentFrame)
        print("PASS expanded conversation stays in its main window during four-edge title drags and never invokes window dragging")
        for size in [NSSize(width: 700, height: 500), NSSize(width: 440, height: 490), NSSize(width: 1180, height: 800)] {
            panel.setContentSize(size); container.layoutSubtreeIfNeeded()
            precondition(container.bounds.insetBy(dx: 8, dy: 8).contains(conversation.frame))
        }
        let chatFrame = conversation.frame
        for origin in [NSPoint(x: -1800, y: 450), NSPoint(x: 2200, y: -600), NSPoint(x: 100, y: 100)] {
            panel.setFrameOrigin(origin)
            precondition(conversation.frame == chatFrame && conversation.window === panel)
        }
        embeddedModel.input = "Preserved draft"
        embeddedBar.collapseButton.performClick(nil)
        precondition(conversation.isHidden && !container.bubble.isHidden && !embeddedModel.conversationVisible)
        embeddedModel.conversationVisible = true; container.updateVisibility()
        precondition(!conversation.isHidden && conversation.frame == chatFrame && embeddedModel.input == "Preserved draft")
        print("PASS expanded chat resizes inside its parent, follows negative/other-display window positions and preserves state on collapse")

        let model = AssistantModel(preview: true)
        var collapsed = 0
        var titleDrags = 0
        let host = AssistantHostingView(rootView: AssistantView(model: model, collapse: { collapsed += 1 }, drag: { _ in titleDrags += 1 }))
        let chatPanel = DragProbePanel(contentRect: NSRect(x: 300, y: 100, width: 480, height: 650),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        chatPanel.contentView = host
        precondition(!host.mouseDownCanMoveWindow && host.acceptsFirstMouse(for: nil))
        for width in [420.0, 480.0, 700.0] {
            chatPanel.setContentSize(NSSize(width: width, height: 650))
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            guard let bar = descendants(host).compactMap({ $0 as? AssistantTitleBarView }).first else { fatalError("Missing title bar") }
            bar.layoutSubtreeIfNeeded()
            let button = bar.collapseButton
            precondition(button.frame.size == NSSize(width: 36, height: 36), "Button: \(button.frame), bar: \(bar.frame), host: \(host.frame)")
            precondition(button.acceptsFirstMouse(for: nil) && !button.mouseDownCanMoveWindow)
            precondition(!bar.dragArea.frame.intersects(button.frame))
            for point in [NSPoint(x: 2, y: 2), NSPoint(x: 34, y: 2), NSPoint(x: 2, y: 34), NSPoint(x: 34, y: 34), NSPoint(x: 18, y: 18)] {
                // NSView.hitTest takes a point in its superview's coordinates (not its own).
                let location = button.convert(point, to: host.superview)
                let hit = host.hitTest(location)
                precondition(hit === button, "Collapse target missed at \(width) / \(point); host point: \(location), hit: \(String(describing: hit)), bar hit: \(String(describing: bar.hitTest(button.convert(point, to: bar.superview))))")
            }
            let before = collapsed
            button.performClick(nil)
            precondition(collapsed == before + 1 && chatPanel.dragCount == 0)
            let beforeDrag = titleDrags
            bar.dragArea.mouseDown(with: event(.leftMouseDown, .zero))
            bar.dragArea.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 100, y: 100)))
            bar.dragArea.mouseUp(with: event(.leftMouseUp, NSPoint(x: 100, y: 100)))
            precondition(titleDrags == beforeDrag + 1 && chatPanel.dragCount == 0)
        }
        print("PASS full collapse hit area at three widths; click routes to collapse, title dragging never moves the parent window")
        model.busy = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let bar = descendants(host).compactMap({ $0 as? AssistantTitleBarView }).first!
        precondition(!bar.settingsButton.isEnabled && bar.collapseButton.isEnabled)
        let before = collapsed; bar.collapseButton.performClick(nil)
        precondition(collapsed == before + 1)
        print("PASS collapse remains available during analysis")

        let appModel = AppModel(preview: true)
        appModel.assistant.floatingIconEnabled = true
        let rootHost = NSHostingView(rootView: RootView(model: appModel))
        let rootPanel = DragProbePanel(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        rootPanel.contentView = rootHost
        rootHost.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        rootHost.layoutSubtreeIfNeeded()
        let embedded = descendants(rootHost).compactMap { $0 as? AssistantBubbleContainer }.first!
        precondition(embedded.bubble.window === rootPanel && !embedded.bubble.isHidden)
        let iconPoint = embedded.bubble.convert(NSPoint(x: 32, y: 32), to: rootHost.superview)
        precondition(rootHost.hitTest(iconPoint) === embedded.bubble)
        let windowCount = NSApplication.shared.windows.count
        appModel.openAssistant()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(embedded.bubble.isHidden && !embedded.conversation.isHidden)
        precondition(embedded.conversation.window === rootPanel && NSApplication.shared.windows.count == windowCount)
        rootHost.layoutSubtreeIfNeeded()
        let rootBar = descendants(embedded.conversation).compactMap { $0 as? AssistantTitleBarView }.first!
        let rootCollapsePoint = rootBar.collapseButton.convert(NSPoint(x: 18, y: 18), to: rootHost.superview)
        precondition(rootHost.hitTest(rootCollapsePoint) === rootBar.collapseButton)
        rootBar.collapseButton.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(!embedded.bubble.isHidden && embedded.conversation.isHidden && !appModel.assistant.conversationVisible)
        print("PASS real main view opens both assistant states in the same window, creates no extra window and routes collapse correctly")
        print("Assistant window checks: 6/6 passed")
    }
}
