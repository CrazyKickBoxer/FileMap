import Foundation

/// Locations the app refuses to move, rename, or trash.
enum ProtectedPaths {
    /// Top-level folders that hold the system together even though they are not "system" files.
    static let structural: Set<String> = ["/", "/Users", "/Applications", "/Volumes", "/opt", "/Network"]

    static func isProtected(_ path: String) -> Bool {
        if ScanPolicy.isSystem(path) { return true }
        if structural.contains(path) { return true }
        if path == NSHomeDirectory() { return true }
        // A volume root under /Volumes.
        if path.parentPath == "/Volumes" { return true }
        return false
    }

    /// Plain-language reason an item can't be changed, or nil if it can.
    static func reasonBlocked(_ node: Node) -> String? {
        if node.isSystem || ScanPolicy.isSystem(node.path) {
            return "\(node.name) is part of macOS. System locations are protected so they can't be moved, renamed, or deleted from FileMap."
        }
        if isProtected(node.path) {
            return "\(node.name) is a top-level location that other things depend on, so FileMap won't change it."
        }
        return nil
    }

    static func reasonBlocked(destination path: String) -> String? {
        if ScanPolicy.isSystem(path) {
            return "Items can't be placed inside system locations such as \(path)."
        }
        return nil
    }
}
