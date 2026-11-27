import AppKit
import Darwin

/// Detects and requests Full Disk Access.
enum FullDiskAccess {
    /// Reading the TCC database is only possible with Full Disk Access.
    static func isGranted() -> Bool {
        let probes = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        for path in probes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
        }
        return false
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Paths mapped without Full Disk Access.
    static var limitedRoots: [String] {
        [NSHomeDirectory(), "/Applications", "/Volumes"]
    }
}
