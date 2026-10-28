import SwiftUI
import AppKit
import QingfengCore

@main enum Launcher {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--scan-json"), args.count > index + 1 {
            var report = DiskScanner(progress: { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }).scan()
            report.items = report.items.map { item in
                var measurement = item.measurement; measurement.entries.removeAll()
                return ScanItem(path: item.path, title: item.title, category: item.category, note: item.note,
                                measurement: measurement, eligible: item.eligible, suggested: item.suggested)
            }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
                print("Read-only scan completed: \(report.items.count) items, \(report.issues.count) notices")
            } catch { fputs("\(error)\n", stderr); exit(1) }
            return
        }
        if let index = args.firstIndex(of: "--snapshot"), args.count > index + 2 {
            snapshot(reportPath: args[index + 1], output: args[index + 2], page: args.last == "clean" ? .clean : .overview)
            return
        }
        QingfengApp.main()
    }

    @MainActor static func snapshot(reportPath: String, output: String, page: Page) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: reportPath)),
           let report = try? JSONDecoder().decode(ScanReport.self, from: data) {
            model.report = report; model.status = "扫描完成 · \(report.date.formatted(date: .omitted, time: .shortened))"
        }
        model.page = page
        let view = NSHostingView(rootView: RootView(model: model))
        let size = NSSize(width: 1180, height: 800)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; window.setContentSize(size); window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: output)); print("Snapshot saved: \(output)") }
        catch { fputs("\(error)\n", stderr); exit(1) }
        window.orderOut(nil)
    }
}

struct QingfengApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("清风", id: "main") {
            RootView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("整理") {
                Button("扫描此 Mac") { model.scan() }.keyboardShortcut("r").disabled(model.busy)
                Button("停止扫描") { model.cancel() }.disabled(!model.busy)
                Divider()
                Button("选择文件夹查找大文件…") { model.openFolderPicker() }.disabled(model.busy)
                Button("导出扫描报告…") { model.exportReport() }.disabled(model.report == nil || model.busy)
                Button("扫描设置…") { model.openSettings() }.disabled(model.busy)
                Divider()
                Button("打开废纸篓") { model.openTrash() }
            }
        }
    }
}
