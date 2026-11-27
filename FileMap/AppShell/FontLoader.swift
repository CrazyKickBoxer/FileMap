import CoreText
import Foundation

/// Registers the bundled Nerd Font at launch and remembers its PostScript name.
enum FontLoader {
    nonisolated(unsafe) private(set) static var glyphFontName = "JetBrainsMonoNF-Regular"

    static func registerBundledFonts() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let message = error?.takeRetainedValue().localizedDescription ?? "unknown"
                // Already registered is fine (e.g. tests hosting the app twice).
                Log.app.info("Font registration: \(message, privacy: .public)")
            }
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
               let first = descriptors.first,
               let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String {
                glyphFontName = name
                Log.app.info("Registered glyph font \(name, privacy: .public)")
            }
        }
        if urls.isEmpty { Log.app.error("Bundled Nerd Font not found") }
    }
}
