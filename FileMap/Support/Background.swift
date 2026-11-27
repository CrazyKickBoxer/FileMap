import Foundation

/// Runs blocking disk work off the main actor.
enum Background {
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}

extension String {
    /// The parent directory of an absolute path ("/" for top-level items).
    var parentPath: String {
        guard self != "/" else { return "/" }
        let trimmed = hasSuffix("/") ? String(dropLast()) : self
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        if slash == trimmed.startIndex { return "/" }
        return String(trimmed[..<slash])
    }

    /// Last path component of an absolute path.
    var lastPathComponentFast: String {
        guard self != "/" else { return "/" }
        guard let slash = lastIndex(of: "/") else { return self }
        return String(self[index(after: slash)...])
    }

    /// Joins a child name onto a directory path.
    func appendingPathComponentFast(_ name: String) -> String {
        self == "/" ? "/" + name : self + "/" + name
    }

    /// True if self equals `ancestor` or lives below it.
    func isInside(_ ancestor: String) -> Bool {
        if ancestor == "/" { return hasPrefix("/") }
        return self == ancestor || hasPrefix(ancestor + "/")
    }
}
