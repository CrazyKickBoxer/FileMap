import AppKit
import Foundation

/// What to do when the destination already has an item with the same name.
enum ConflictChoice: Sendable { case keepBoth, replace, skip, cancel }

@MainActor
protocol ConflictResolving {
    /// Returns the choice and whether it should apply to all remaining conflicts.
    func resolve(name: String, destination: String, remaining: Int) -> (ConflictChoice, applyToAll: Bool)
    /// Asks before a large trash. Returns true to continue.
    func confirmTrash(count: Int, bytes: Int64) -> Bool
}

/// Asks the user with standard alerts.
struct AlertConflictResolver: ConflictResolving {
    func resolve(name: String, destination: String, remaining: Int) -> (ConflictChoice, applyToAll: Bool) {
        let alert = NSAlert()
        alert.messageText = "An item named “\(name)” already exists in “\(destination.lastPathComponentFast)”."
        alert.informativeText = "Do you want to keep both, replace the existing item (it goes to the Trash), or skip this one?"
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Stop")
        if remaining > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Apply to all \(remaining) conflicts"
        }
        let response = alert.runModal()
        let all = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return (.keepBoth, all)
        case .alertSecondButtonReturn: return (.replace, all)
        case .alertThirdButtonReturn: return (.skip, all)
        default: return (.cancel, true)
        }
    }

    func confirmTrash(count: Int, bytes: Int64) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move \(Format.items(Int64(count))) (\(Format.bytes(bytes))) to the Trash?"
        alert.informativeText = "You can put them back with Undo or from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Fixed answers, for tests.
struct FixedConflictResolver: ConflictResolving {
    var choice: ConflictChoice = .keepBoth
    var confirm = true
    func resolve(name: String, destination: String, remaining: Int) -> (ConflictChoice, applyToAll: Bool) { (choice, true) }
    func confirmTrash(count: Int, bytes: Int64) -> Bool { confirm }
}

enum NameCollision {
    /// "name 2.ext", "name 3.ext", … the first one that doesn't exist.
    static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
