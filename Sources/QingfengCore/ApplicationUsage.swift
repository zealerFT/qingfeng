import Foundation

public struct RunningApplicationInfo: Sendable {
    public let bundleID: String
    public let name: String
    public let version: String?
    public let processID: Int32
    public let jetBrainsDirectory: String?
    public init(bundleID: String, name: String, version: String? = nil, processID: Int32 = 0,
                jetBrainsDirectory: String? = nil) {
        self.bundleID = bundleID; self.name = name; self.version = version
        self.processID = processID; self.jetBrainsDirectory = jetBrainsDirectory
    }
    public var label: String {
        "\(name)\(version.map { " " + $0 } ?? "")（PID \(processID)）"
    }
}

public enum ApplicationUsage {
    public static func blockers(for path: String, applications: [RunningApplicationInfo]) -> [RunningApplicationInfo] {
        applications.filter { matches(path: path, application: $0) }
    }

    private static func matches(path: String, application app: RunningApplicationInfo) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let bundle = app.bundleID.lowercased()
        guard !bundle.isEmpty else { return false }
        if let index = components.firstIndex(of: "JetBrains"),
           index >= 2, components[index - 2] == "Library", components[index - 1] == "Caches",
           components.count > index + 1 {
            guard bundle.hasPrefix("com.jetbrains.") else { return false }
            let target = components[index + 1].lowercased()
            if let selector = app.jetBrainsDirectory, !selector.isEmpty {
                // JetBrains declares the exact default cache directory in product-info.json.
                return target == selector.lowercased()
            }
            // If the version selector is unavailable, protect this product only, not the vendor's other IDEs.
            let product = String(target.prefix { !$0.isNumber })
            let families: [String: [String]] = [
                "goland": ["goland"], "intellij": ["intellijidea", "ideaic"],
                "pycharm": ["pycharm", "pycharmce"], "datagrip": ["datagrip"],
                "dataspell": ["dataspell"], "clion": ["clion"], "phpstorm": ["phpstorm"],
                "webstorm": ["webstorm"], "rider": ["rider"], "rustrover": ["rustrover"], "aqua": ["aqua"]
            ]
            let appProduct = bundle.dropFirst("com.jetbrains.".count).split(separator: ".").first.map(String.init) ?? ""
            return families[appProduct]?.contains(product) ?? false
        }
        let token = components.last?.lowercased() ?? ""
        let name = app.name.lowercased().replacingOccurrences(of: " ", with: "")
        if token == bundle || token.hasPrefix(bundle + ".") { return true }
        if name.count > 3 && token.replacingOccurrences(of: " ", with: "").contains(name) { return true }
        if token == "google" { return bundle == "com.google.chrome" || bundle.hasPrefix("com.google.chrome.") }
        if token == "larkshell" { return bundle.contains("lark") }
        return false
    }

    public static func blockingReason(for path: String, applications: [RunningApplicationInfo]) -> String? {
        let matches = blockers(for: path, applications: applications)
        guard !matches.isEmpty else { return nil }
        return "检测到对应应用仍在运行：" + matches.map(\.label).joined(separator: "、") + "。请退出列出的应用后重新扫描。"
    }
}
