import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Maps file extensions to a UTType identifier, a `FileKind`, and package-ness.
/// Results are cached per extension, so classification is a dictionary lookup on the hot path.
final class TypeClassifier: Sendable {
    struct Info: Sendable {
        var uti: String?
        var kind: FileKind
        var isPackage: Bool
    }

    static let shared = TypeClassifier()

    private let fileCache = Mutex<[String: Info]>([:])
    private let dirCache = Mutex<[String: Info]>([:])

    /// Extensions treated as code even when the system has no type for them.
    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "go", "rs", "kt", "kts", "java", "scala",
        "py", "rb", "php", "pl", "lua", "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte", "sh", "zsh",
        "bash", "fish", "gd", "gdshader", "tscn", "tres", "json", "yaml", "yml", "toml", "xml", "html", "css",
        "scss", "sass", "less", "sql", "graphql", "proto", "gradle", "cmake", "make", "dart", "zig", "nim",
        "ex", "exs", "erl", "hs", "ml", "clj", "r", "jl", "metal", "glsl", "hlsl", "wgsl", "ipynb", "xcconfig",
        "plist", "entitlements", "strings", "storyboard", "xib", "lock", "env", "ini", "cfg", "conf",
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "dmg", "iso", "pkg", "zst", "lz4", "sparseimage", "xip",
    ]

    static func fileExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 24 else { return nil }
        return ext.lowercased()
    }

    func info(forName name: String, isDirectory: Bool) -> Info {
        guard let ext = Self.fileExtension(of: name) else {
            return isDirectory ? Info(uti: UTType.folder.identifier, kind: .folder, isPackage: false)
                               : Info(uti: nil, kind: .other, isPackage: false)
        }
        if let hit = (isDirectory ? dirCache.withLock { $0[ext] } : fileCache.withLock { $0[ext] }) { return hit }
        let info = Self.classify(ext: ext, isDirectory: isDirectory)
        if isDirectory { dirCache.withLock { $0[ext] = info } } else { fileCache.withLock { $0[ext] = info } }
        return info
    }

    private static func classify(ext: String, isDirectory: Bool) -> Info {
        if isDirectory {
            guard let type = UTType(filenameExtension: ext, conformingTo: .directory), type.conforms(to: .package) else {
                return Info(uti: UTType.folder.identifier, kind: .folder, isPackage: false)
            }
            return Info(uti: type.identifier, kind: kind(for: type, ext: ext), isPackage: true)
        }
        let type = UTType(filenameExtension: ext)
        let kind = type.map { kind(for: $0, ext: ext) } ?? fallbackKind(ext)
        let uti = type.flatMap { $0.isDynamic ? nil : $0.identifier }
        return Info(uti: uti, kind: kind, isPackage: false)
    }

    static func kind(for type: UTType, ext: String) -> FileKind {
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) || type.conforms(to: .applicationExtension) {
            return .app
        }
        if type.conforms(to: .image) { return .picture }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if codeExtensions.contains(ext) || type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .shellScript) {
            return .code
        }
        if archiveExtensions.contains(ext) || type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) || type.conforms(to: .rtf)
            || type.conforms(to: .epub) {
            return .document
        }
        return fallbackKind(ext)
    }

    private static func fallbackKind(_ ext: String) -> FileKind {
        if codeExtensions.contains(ext) { return .code }
        if archiveExtensions.contains(ext) { return .archive }
        return .other
    }
}
