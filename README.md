# FileMap

A native macOS app that shows your whole drive as a zoomable, flowchart-style map. Folders are glass boxes, curved lines join parents to children, and every file action happens on the map itself.

## Build

Requirements: macOS 27, Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
```

```bash
xcodebuild -project FileMap.xcodeproj -scheme FileMap -derivedDataPath ~/Library/Developer/FileMapBuild build
```

```bash
xcodebuild -project FileMap.xcodeproj -scheme FileMap -derivedDataPath ~/Library/Developer/FileMapBuild test
```

Or open `FileMap.xcodeproj` in Xcode and press ⌘R. `project.yml` is the source of truth for the project; regenerate after adding files.

Keep build output **out of** `~/Documents` (use `-derivedDataPath` as above or Xcode's default DerivedData). If Documents syncs with iCloud, hundreds of MB of build churn can stall the file provider.

Signing uses the "Apple Development" certificate (team `74D6654UM8`) with manual signing. For distribution, switch `CODE_SIGN_IDENTITY` to a Developer ID certificate and notarize. The app is not sandboxed (it needs Full Disk Access to map the whole drive).

### Headless helpers

```bash
FileMap.app/Contents/MacOS/FileMap --scan /Applications --db /tmp/apps.sqlite
```

```bash
FileMap.app/Contents/MacOS/FileMap --verify /Applications /Applications/Utilities --db /tmp/apps.sqlite
```

`--verify` compares the index's on-disk totals with `du -sk` (hard links are counted once, as `du` does).

## How the modules fit together

```
Scanner ──writes──▶ Index (SQLite/GRDB, WAL) ◀──patches── Watcher (FSEvents)
                       │                                      ▲
                       ▼                                      │
   Layout ◀── MapModel (Interaction) ──▶ FileOps ─────────────┘ (patches right after each action)
     │            │      ▲
     ▼            ▼      │
  MapScene ──▶ SceneBuilder ──▶ RenderFrame ──▶ MapRenderer (Canvas today; Metal-ready)
                                   Clusters, Search, Pins read the Index directly
```

| Folder | Job |
|---|---|
| `Scanner/` | `BulkDirectoryReader` lists folders with `getattrlistbulk`. `Scanner` (actor) scans the first 3 levels itself, then walks the subtrees below in parallel (max 6 workers). Each subtree's totals are added to its ancestors when it finishes, so sizes grow live. Pausable, cancellable, and resumable across launches. |
| `Index/` | Schema and migrations (`IndexStore`), read queries (`NodeQueries`), writes and roll-ups (`NodeWrites`), and the `meta` table (scan state, last FSEvents id, saved view state). The trigram FTS5 index powers substring search. |
| `Watcher/` | `FSEventStream` wraps the C API. `Watcher` (actor) replays events since the last saved id. `IndexPatcher` re-checks changed paths and fixes the totals up the parent chain. It is idempotent and also used by FileOps. |
| `Layout/` | `TreeInputBuilder` decides box sizes and labels. `TidyTreeLayout` is a contour-based tidy tree (no overlaps). `NestedGridLayout` handles cluster view. Both produce a `MapScene`. |
| `MapRenderer/` | `SceneBuilder` culls whole branches using subtree bounds, picks the level of detail, and draws tiny branches as single bands. `CanvasMapRenderer` draws a `RenderFrame`. `Theme` holds the colors; `GlyphTable` holds the icons. |
| `Interaction/` | `MapModel` holds state, animations, fly-to and keyboard navigation. `InteractionView` (AppKit) handles trackpad, mouse, keys, drag & drop, Quick Look, and VoiceOver elements. `MapActions` holds every command. |
| `FileOps/` | Reversible `FileStep`s run off the main thread, with undo/redo through `UndoManager`. Trash only (never permanent delete), conflict prompts, protected paths. |
| `Clusters/` | `ClusterQuery` (SQL grouping by type → year → month, date bucket → kind, project → kind), `ClusterController`, `ProjectDetector`. |
| `Search/`, `Pins/` | Search-as-you-type with filters; pins that follow moved targets through bookmarks. |
| `AppShell/` | App entry, onboarding/Full Disk Access, toolbar, panels, settings, headless commands. |

To swap the renderer for Metal, write an `MTKView`-backed type that conforms to `MapRenderer` and draws `RenderFrame`, then change `typealias ActiveMapRenderer` in `MapRenderer/MapRenderer.swift`.

## Editing the glyph table

All icons come from the bundled JetBrainsMono Nerd Font (`FileMap/Resources/Fonts`, SIL Open Font License in `OFL.txt`), registered at launch by `FontLoader`. Edit `FileMap/MapRenderer/GlyphTable.swift`:

- `byExtension`: lower-case extension → glyph (checked first)
- `byUTType`: exact UTType identifier → glyph
- `byKind`: fallback per file kind

Find code points on the [Nerd Fonts cheat sheet](https://www.nerdfonts.com/cheat-sheet) and write them as `"\u{F1C5}"`. Kind colors live in `MapRenderer/Theme.swift`.

## Using it

- **Trackpad:** two-finger scroll pans, pinch zooms, smart-zoom double-tap fits the selected folder.
- **Mouse:** the wheel zooms toward the cursor, and dragging empty space pans. Shift- or ⌘-drag on empty space draws a selection rectangle.
- **Clicks:**
  - Click a folder to select and expand it; click it again to collapse.
  - Double-click a file (or press Return) to open it; double-clicking a folder zooms to it.
  - Click the name of a selected item (or press F2) to rename it.
- **Keyboard:**
  - Arrows move the selection; Space opens Quick Look.
  - ⌘⌫ moves to the Trash; ⇧⌘N makes a new folder; ⌘D pins.
  - ⌘F finds; ⌘0 fits the whole map; ⌘↑ goes to the parent; ⇧⌘H goes home; ⌘1/2/3 switch views; ⌘Z / ⇧⌘Z undo and redo.
- **Drag:** drag boxes onto folders to move them (⌥ copies). Hovering over a closed folder opens it. You can drag to and from Finder.
- **Debug menu:** builds a 1,111,111-node test tree and shows the frame rate.

## Tests

`FileMapTests/` (Swift Testing) cover scanner roll-ups (including packages, symlinks, hard links, no-access folders, exclusions), watcher patching, layout overlap, cluster queries, project detection, search speed, every file operation with undo/redo, and a frame-building benchmark on the 1M-node tree. File operations run only inside `~/.filemap-tests/<uuid>`, which is deleted afterwards. Trash tests restore what they trash.
