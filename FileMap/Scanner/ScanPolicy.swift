import Darwin
import Foundation

/// Rules for what to scan and how to flag it.
struct ScanPolicy: Sendable {
    /// Folders/volumes the user excluded in Settings.
    var excludedPaths: [String] = []
    /// Treat `.app` and other bundles as single items.
    var treatPackagesAsItems = true
    /// When set (no Full Disk Access), only these subtrees and their ancestors are scanned.
    var allowedPaths: [String]?

    /// System locations: hidden by default and protected from move/rename/delete.
    static let systemPrefixes = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/cores", "/dev", "/etc", "/var", "/tmp"]

    /// Never walked: firmlink mirrors, magic directories, and pseudo file systems
    /// that would make us count the same data twice or recurse forever.
    static let skippedPaths: Set<String> = [
        "/System/Volumes", "/dev", "/.nofollow", "/.resolve", "/.vol", "/net", "/home", "/.fseventsd",
        "/.Spotlight-V100", "/.DocumentRevisions-V100", "/.PKInstallSandboxManager-SystemSoftware",
        "/Volumes/com.apple.TimeMachine.localsnapshots", "/Volumes/.timemachine", "/.MobileBackups",
    ]

    static func isSystem(_ path: String) -> Bool {
        systemPrefixes.contains { path.isInside($0) }
    }

    static func isHidden(name: String, flags: UInt32, path: String = "") -> Bool {
        // /Volumes carries UF_HIDDEN, but external drives should always be visible.
        if path == "/Volumes" || path.parentPath == "/Volumes" { return name.hasPrefix(".") }
        return name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0
    }

    /// Whether the scanner should skip `path` entirely.
    func shouldSkip(_ path: String) -> Bool {
        if Self.skippedPaths.contains(path) { return true }
        if excludedPaths.contains(where: { path.isInside($0) }) { return true }
        if let allowedPaths {
            let allowed = allowedPaths.contains { path.isInside($0) || $0.isInside(path) }
            if !allowed { return true }
        }
        return false
    }

    /// Whether to descend into a mount point. Only local, browsable volumes under /Volumes qualify;
    /// everything else (e.g. /System/Volumes/*) is a duplicate view of data we already walk.
    func shouldDescend(intoMountPoint path: String) -> Bool {
        guard path.parentPath == "/Volumes" else { return false }
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        let flags = UInt32(fs.f_flags)
        if flags & UInt32(MNT_LOCAL) == 0 { return false }
        if flags & UInt32(MNT_DONTBROWSE) != 0 { return false }
        return true
    }
}
