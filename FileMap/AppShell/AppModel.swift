import AppKit
import Foundation
import Observation

/// Owns the long-lived services (index, scanner, watcher) and the app's top-level state.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case onboarding, ready, failed(String) }

    let settings = AppSettings()
    private(set) var phase: Phase = .onboarding
    private(set) var store: IndexStore?
    private(set) var map: MapModel?
    private(set) var fileOps: FileOperations?
    private(set) var pins: PinStore?
    private(set) var search: SearchModel?
    private(set) var scanProgress: ScanProgress?
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted()
    private(set) var scanInterrupted = false
    var showFPS = false

    @ObservationIgnored private var scanner: Scanner?
    @ObservationIgnored private var watcher: Watcher?
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var scanRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    static var isRunningTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    init() {
        FontLoader.registerBundledFonts()
        guard !Self.isRunningTests else {
            phase = .failed("Running tests")
            return
        }
        do {
            let store = try IndexStore(url: try IndexStore.defaultURL())
            self.store = store
            let map = MapModel(store: store, settings: settings)
            let patcher = IndexPatcher(store: store, policy: scanPolicy, ignoredPrefixes: [store.directoryPath])
            let fileOps = FileOperations(store: store, patcher: patcher, undoManager: map.undoManager, settings: settings)
            let pins = PinStore(store: store)
            map.fileOps = fileOps
            map.pins = pins
            fileOps.onPatch = { [weak map] result in map?.apply(result) }
            fileOps.onError = { [weak map] title, message in map?.report(title, message: message) }
            self.map = map
            self.fileOps = fileOps
            self.pins = pins
            self.search = SearchModel(store: store, settings: settings)
            self.scanner = Scanner(store: store)
        } catch {
            phase = .failed("FileMap couldn't open its index: \(error.localizedDescription)")
            return
        }
        if settings.onboardingDone || hasFullDiskAccess {
            settings.onboardingDone = true
            phase = .ready
            Task { await start() }
        } else {
            watchForPermission()
        }
    }

    // MARK: Permissions

    var isLimited: Bool { !hasFullDiskAccess }

    var scanPolicy: ScanPolicy {
        settings.scanPolicy(limitedTo: hasFullDiskAccess ? nil : FullDiskAccess.limitedRoots)
    }

    /// Polls for Full Disk Access and continues on its own once it is granted.
    func watchForPermission() {
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                if FullDiskAccess.isGranted() {
                    self.permissionGranted()
                    return
                }
            }
        }
    }

    private func permissionGranted() {
        let wasLimited = !hasFullDiskAccess
        hasFullDiskAccess = true
        permissionTask?.cancel()
        Log.app.info("Full Disk Access granted")
        if phase == .onboarding {
            settings.onboardingDone = true
            settings.limitedMode = false
            phase = .ready
            Task { await start() }
        } else if wasLimited, started {
            // Map the rest of the drive now that we can see it.
            settings.limitedMode = false
            rescan()
        }
    }

    func continueWithoutAccess() {
        settings.onboardingDone = true
        settings.limitedMode = true
        phase = .ready
        Task { await start() }
        watchForPermission()
    }

    // MARK: Startup

    private func start() async {
        guard !started, let store, let map, let pins else { return }
        started = true
        await pins.load()
        await map.load()
        let state = (try? await store.read { db in try Meta.get(db, "scan_state") }) ?? nil
        switch state {
        case "complete":
            startWatcher()
        case "running":
            scanInterrupted = true
            startScan(resume: true)
        default:
            startScan(resume: false)
        }
        if !hasFullDiskAccess { watchForPermission() }
    }

    // MARK: Scanning

    var isScanning: Bool { scanProgress?.isActive == true }

    func startScan(resume: Bool) {
        guard let scanner, let map else { return }
        stopWatcher()
        scanInterrupted = false
        scanProgress = ScanProgress(phase: .preparing)
        let policy = scanPolicy
        Task {
            await scanner.start(roots: ["/"], policy: policy, resume: resume, onProgress: { progress in
                Task { @MainActor [weak self] in self?.scanProgress = progress }
            }, onFinish: { phase in
                Task { @MainActor [weak self] in self?.scanFinished(phase) }
            })
        }
        // Show what is indexed so far.
        scanRefreshTask?.cancel()
        scanRefreshTask = Task { [weak map] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled, let map else { return }
                await map.refreshAll()
            }
        }
    }

    private func scanFinished(_ phase: ScanProgress.Phase) {
        scanRefreshTask?.cancel()
        scanRefreshTask = nil
        if case .done = phase {
            startWatcher()
            scanInterrupted = false
        } else if case .cancelled = phase {
            scanInterrupted = true
        } else if case .failed(let message) = phase {
            map?.report("The scan stopped", message: message)
            scanInterrupted = true
        }
        Task {
            await map?.refreshAll()
            await pins?.load()
            map?.relayout(animated: false)
        }
    }

    func pauseScan() { Task { await scanner?.pause() } }
    func resumeScan() { Task { await scanner?.resume() } }
    func cancelScan() { Task { await scanner?.cancel() } }

    func rescan() {
        guard let store, let map else { return }
        Task {
            await scanner?.cancel()
            while await scanner?.isRunning == true { try? await Task.sleep(for: .milliseconds(100)) }
            stopWatcher()
            do { try store.clearIndex() } catch { map.report("Couldn't clear the index", error) }
            await map.reset()
            startScan(resume: false)
        }
    }

    func clearIndex() {
        guard let store, let map else { return }
        Task {
            await scanner?.cancel()
            while await scanner?.isRunning == true { try? await Task.sleep(for: .milliseconds(100)) }
            stopWatcher()
            do { try store.clearIndex() } catch { map.report("Couldn't clear the index", error) }
            await map.reset()
            scanProgress = nil
            scanInterrupted = true
        }
    }

    // MARK: Watching

    private func startWatcher() {
        guard let store, watcher == nil else { return }
        let patcher = IndexPatcher(store: store, policy: scanPolicy, ignoredPrefixes: [store.directoryPath])
        fileOps?.patcher = patcher
        let watcher = Watcher(store: store, patcher: patcher) { [weak self] result in
            Task { @MainActor in self?.map?.apply(result) }
        }
        self.watcher = watcher
        Task { await watcher.start(paths: ["/"]) }
    }

    private func stopWatcher() {
        guard let watcher else { return }
        self.watcher = nil
        Task { await watcher.stop() }
    }

    func policyChanged() {
        let policy = scanPolicy
        fileOps?.patcher.policy = policy
        if let watcher { Task { await watcher.updatePolicy(policy) } }
    }

    func willTerminate() {
        map?.saveState()
    }
}
