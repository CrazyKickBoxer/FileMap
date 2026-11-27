import Foundation

/// The one place that maps file types to Nerd Font glyphs. Edit freely:
/// - `byExtension` wins first (lower-case extension, no dot),
/// - then `byUTType` (exact UTType identifier),
/// - then `byKind` (the coarse kind used for colour).
/// Code points come from the Nerd Fonts cheat sheet (https://www.nerdfonts.com/cheat-sheet).
enum GlyphTable {
    static let folder = "\u{F07B}"         // nf-fa-folder
    static let folderOpen = "\u{F07C}"     // nf-fa-folder_open
    static let volume = "\u{F0A0}"         // nf-fa-hdd_o
    static let more = "\u{F141}"           // nf-fa-ellipsis_h
    static let pin = "\u{F08D}"            // nf-fa-thumb_tack
    static let lock = "\u{F023}"           // nf-fa-lock
    static let link = "\u{F0C1}"           // nf-fa-link
    static let calendar = "\u{F073}"       // nf-fa-calendar
    static let project = "\u{F126}"        // nf-fa-code_fork
    static let home = "\u{F015}"           // nf-fa-home
    static let search = "\u{F002}"         // nf-fa-search

    static let byKind: [FileKind: String] = [
        .folder: folder,
        .picture: "\u{F1C5}",   // nf-fa-file_image_o
        .video: "\u{F1C8}",     // nf-fa-file_video_o
        .audio: "\u{F1C7}",     // nf-fa-file_audio_o
        .document: "\u{F0F6}",  // nf-fa-file_text_o
        .code: "\u{F1C9}",      // nf-fa-file_code_o
        .archive: "\u{F1C6}",   // nf-fa-file_archive_o
        .app: "\u{F1B2}",       // nf-fa-cube
        .other: "\u{F016}",     // nf-fa-file_o
    ]

    static let byExtension: [String: String] = [
        "pdf": "\u{F1C1}",                                       // nf-fa-file_pdf_o
        "doc": "\u{F1C2}", "docx": "\u{F1C2}", "pages": "\u{F1C2}", // nf-fa-file_word_o
        "xls": "\u{F1C3}", "xlsx": "\u{F1C3}", "numbers": "\u{F1C3}", "csv": "\u{F1C3}", // nf-fa-file_excel_o
        "ppt": "\u{F1C4}", "pptx": "\u{F1C4}", "key": "\u{F1C4}",    // nf-fa-file_powerpoint_o
        "swift": "\u{E755}",                                      // nf-dev-swift
        "py": "\u{E73C}",                                         // nf-dev-python
        "js": "\u{E74E}", "mjs": "\u{E74E}", "ts": "\u{E74E}",    // nf-dev-javascript
        "rs": "\u{E7A8}",                                         // nf-dev-rust
        "go": "\u{E626}",                                         // nf-seti-go
        "html": "\u{F13B}", "css": "\u{F13C}",                    // nf-fa-html5 / css3
        "json": "\u{E60B}",                                       // nf-seti-json
        "md": "\u{F48A}",                                         // nf-oct-markdown
        "sh": "\u{F120}", "zsh": "\u{F120}", "bash": "\u{F120}",  // nf-fa-terminal
        "sqlite": "\u{F1C0}", "db": "\u{F1C0}", "sql": "\u{F1C0}",// nf-fa-database
        "ttf": "\u{F031}", "otf": "\u{F031}",                     // nf-fa-font
        "dmg": "\u{F0A0}", "iso": "\u{F0A0}",                     // nf-fa-hdd_o
        "gd": "\u{E65F}", "godot": "\u{E65F}",                    // nf-seti-godot
        "app": "\u{F179}",                                        // nf-fa-apple
    ]

    static let byUTType: [String: String] = [
        "public.symlink": link,
        "public.volume": volume,
        "com.apple.application-bundle": "\u{F179}",
    ]

    static func glyph(name: String, uti: String?, kind: FileKind, isFolder: Bool, expanded: Bool = false) -> String {
        if isFolder { return expanded ? folderOpen : folder }
        if let ext = TypeClassifier.fileExtension(of: name), let g = byExtension[ext] { return g }
        if let uti, let g = byUTType[uti] { return g }
        return byKind[kind] ?? byKind[.other] ?? ""
    }
}
