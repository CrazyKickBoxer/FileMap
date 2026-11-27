import Foundation

/// The coarse kind of an item. Stored in the `kind` column as its raw value.
enum FileKind: String, Sendable, CaseIterable, Codable, Hashable {
    case folder, picture, video, audio, document, code, archive, app, other

    /// Kinds that can be used to cluster files (folders are not files).
    static let fileKinds: [FileKind] = [.picture, .video, .audio, .document, .code, .archive, .app, .other]

    var displayName: String {
        switch self {
        case .folder: "Folders"
        case .picture: "Pictures"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Documents"
        case .code: "Code"
        case .archive: "Archives"
        case .app: "Apps"
        case .other: "Other"
        }
    }

    init(raw: String?) {
        self = raw.flatMap(FileKind.init(rawValue:)) ?? .other
    }
}
