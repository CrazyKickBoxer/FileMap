import Foundation
import Observation

/// Search-as-you-type state for the glass search bar.
@MainActor
@Observable
final class SearchModel {
    @ObservationIgnored private let store: IndexStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var task: Task<Void, Never>?

    var isPresented = false
    var text = "" { didSet { schedule() } }
    var filters = SearchFilters() { didSet { schedule() } }
    private(set) var results: [Node] = []
    private(set) var elapsedMS: Double = 0
    var highlighted = 0

    init(store: IndexStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    private func schedule() {
        task?.cancel()
        let text = self.text
        let filters = self.filters
        let visibility = settings.visibility
        let store = self.store
        task = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let start = CFAbsoluteTimeGetCurrent()
            let found = (try? await store.read { db in
                try SearchQueries.search(db, text: text, filters: filters, visibility: visibility)
            }) ?? []
            guard !Task.isCancelled else { return }
            elapsedMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
            results = found
            highlighted = 0
            Log.search.debug("“\(text, privacy: .private)” → \(found.count) results in \(self.elapsedMS) ms")
        }
    }

    func moveHighlight(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = max(0, min(results.count - 1, highlighted + delta))
    }

    func dismiss() {
        isPresented = false
    }
}
