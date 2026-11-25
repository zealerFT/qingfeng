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
    }

    @MainActor static func checkWindows() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900),
                       NSRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let size = NSSize(width: 64, height: 64)
        // Crossing a boundary must choose the destination screen even while the old one intersects.
        let crossed = AssistantWindowPlacement.visibleOrigin(NSPoint(x: 1430, y: 400), size: size, screens: screens)
        precondition(crossed.x == 1448)
        let free = NSPoint(x: 2400, y: 700)
        precondition(AssistantWindowPlacement.visibleOrigin(free, size: size, screens: screens) == free)
        let leftScreen = NSRect(x: -1920, y: 200, width: 1920, height: 1080)
        precondition(AssistantWindowPlacement.visibleOrigin(NSPoint(x: -1700, y: 600), size: size, screens: [screens[0], leftScreen]).x == -1700)
        let restored = AssistantWindowPlacement.visibleOrigin(free, size: size, screens: [screens[0]])
        precondition(screens[0].contains(NSRect(origin: restored, size: size)))
        print("PASS destination screen selection, negative coordinates and disconnected-screen recovery")

        let panel = DragProbePanel(contentRect: NSRect(x: 300, y: 300, width: 1180, height: 800),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let container = AssistantBubbleContainer(preview: true)
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

        let model = AssistantModel(preview: true)
        var collapsed = 0
        let host = AssistantHostingView(rootView: AssistantView(model: model, collapse: { collapsed += 1 }))
        let chatPanel = DragProbePanel(contentRect: NSRect(x: 300, y: 100, width: 480, height: 650),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        chatPanel.contentView = host
        precondition(!host.mouseDownCanMoveWindow && host.acceptsFirstMouse(for: nil))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
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
            bar.dragArea.mouseDown(with: event(.leftMouseDown, .zero))
            precondition(chatPanel.dragCount == 1)
            chatPanel.dragCount = 0
        }
        print("PASS full collapse hit area at three widths; click routes to collapse, only title drag moves window")
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
        appModel.assistant.conversationVisible = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(embedded.bubble.isHidden)
        appModel.assistant.conversationVisible = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(!embedded.bubble.isHidden)
        print("PASS real main view embeds icon in the same window and hides/restores it when the conversation opens/collapses")
        print("Assistant window checks: 5/5 passed")
    }
}
