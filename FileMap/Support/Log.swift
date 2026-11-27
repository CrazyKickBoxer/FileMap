import os

/// One logger per module so Console.app can filter by category.
enum Log {
    static let subsystem = "com.filemap.FileMap"
    static let app = Logger(subsystem: subsystem, category: "AppShell")
    static let scanner = Logger(subsystem: subsystem, category: "Scanner")
    static let index = Logger(subsystem: subsystem, category: "Index")
    static let watcher = Logger(subsystem: subsystem, category: "Watcher")
    static let layout = Logger(subsystem: subsystem, category: "Layout")
    static let renderer = Logger(subsystem: subsystem, category: "MapRenderer")
    static let interaction = Logger(subsystem: subsystem, category: "Interaction")
    static let fileOps = Logger(subsystem: subsystem, category: "FileOps")
    static let clusters = Logger(subsystem: subsystem, category: "Clusters")
    static let search = Logger(subsystem: subsystem, category: "Search")
    static let pins = Logger(subsystem: subsystem, category: "Pins")
}
