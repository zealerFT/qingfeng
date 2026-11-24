import Foundation

public enum FileKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case models, applications, video, audio, images, archives, diskImages, documents, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .models: return "模型"
        case .applications: return "应用程序"
        case .video: return "视频"
        case .audio: return "音频"
        case .images: return "图像与照片库"
        case .archives: return "压缩包"
        case .diskImages: return "安装包与磁盘镜像"
        case .documents: return "文稿"
        case .other: return "其他文件"
        }
    }
    public static func classify(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        let path = url.path.lowercased()
        if ["safetensors", "gguf", "ggml", "ckpt", "pth", "pt", "onnx", "mlmodel", "mlpackage"].contains(ext)
            || path.contains("/.ollama/models/") || path.contains("/huggingface/") || path.contains("/.lmstudio/models/") { return .models }
        if ext == "app" { return .applications }
        if ["mp4", "mov", "mkv", "avi", "webm", "m4v", "mts"].contains(ext) { return .video }
        if ["mp3", "flac", "wav", "m4a", "aiff", "aac", "logicx", "band"].contains(ext) { return .audio }
        if ["jpg", "jpeg", "png", "heic", "tiff", "raw", "psd", "photoslibrary"].contains(ext) { return .images }
        if ["zip", "7z", "rar", "tar", "gz", "bz2", "xz"].contains(ext) { return .archives }
        if ["dmg", "pkg", "xip", "iso", "sparsebundle", "sparseimage", "qcow2", "vmdk"].contains(ext) { return .diskImages }
        if ["pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "txt", "md", "csv", "epub"].contains(ext) { return .documents }
        return .other
    }
}

public enum LargeFileSort: String, CaseIterable, Identifiable {
    case logical = "文件大小", allocated = "磁盘占用", accessed = "最近访问"
    public var id: String { rawValue }
}

public struct LargeFileSummary: Codable, Sendable {
    public var roots: [String]
    public var minimumBytes: Int64
    public var visitedEntries = 0
    public var matchedFiles = 0
    public var unreadableEntries = 0
    public var skippedCloudFiles = 0
    public var reachedEntryLimit = false
    public var reachedResultLimit = false
    public var cancelled = false
    public var issueIDs: [String]?
    public var complete: Bool { !reachedEntryLimit && !reachedResultLimit && !cancelled && unreadableEntries == 0 }
    public init(roots: [String], minimumBytes: Int64) { self.roots = roots; self.minimumBytes = minimumBytes }
}

extension ScanItem {
    public var fileKind: FileKind { FileKind.classify(url) }
    public var fileSize: Int64 { logicalBytes ?? bytes }
}
