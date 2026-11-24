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
    @MainActor static func main() {
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

        let panel = DragProbePanel(contentRect: NSRect(x: 300, y: 300, width: 64, height: 64),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let bubble = FloatingAssistantButton(frame: NSRect(origin: .zero, size: size))
        panel.contentView = bubble
        var opened = 0, completedDrags = 0
        bubble.open = { opened += 1 }
        bubble.didDrag = {
            completedDrags += 1
            panel.setFrameOrigin(AssistantWindowPlacement.visibleOrigin(panel.frame.origin, size: size, screens: screens))
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        precondition(bubble.acceptsFirstMouse(for: nil) && !bubble.mouseDownCanMoveWindow)
        bubble.mouseDown(with: event(.leftMouseDown, NSPoint(x: 32, y: 32)))
        bubble.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 33, y: 33)))
        bubble.mouseUp(with: event(.leftMouseUp, NSPoint(x: 33, y: 33)))
        precondition(opened == 1 && panel.dragCount == 0)
        bubble.mouseDown(with: event(.leftMouseDown, NSPoint(x: 32, y: 32)))
        bubble.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 600, y: 200)))
        precondition(panel.dragEventType == .leftMouseDown && completedDrags == 0)
        bubble.mouseUp(with: event(.leftMouseUp, NSPoint(x: 600, y: 200)))
        precondition(panel.dragCount == 1 && completedDrags == 1 && opened == 1)
        precondition(panel.frame.origin == panel.destination)
        bubble.mouseDown(with: event(.leftMouseDown, NSPoint(x: 32, y: 32)))
        bubble.mouseUp(with: event(.leftMouseUp, NSPoint(x: 32, y: 32)))
        precondition(opened == 2)
        print("PASS inactive first click, click jitter, native drag outside original window and next click")

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
        print("Assistant window checks: 4/4 passed")
    }
}
