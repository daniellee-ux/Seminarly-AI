import AppKit
import Combine
import os

private let updateLogger = Logger(subsystem: "ai.seminarly.Seminarly", category: "AutomaticUpdates")

/// App-owned scheduling continues with all windows closed. Probing a signed feed
/// and caching its archive never launches Sparkle's installer or arms install-on-quit.
@MainActor
final class AutomaticUpdateCoordinator: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case available(String)
        case downloading(String)
        case ready(String)

        var version: String? {
            switch self {
            case .idle, .checking: nil
            case .available(let version), .downloading(let version), .ready(let version): version
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var bannerDismissed = false
    private(set) var cachedUpdate: CachedUpdate?
    private let settings: UpdateSettings
    private let cache: UpdateDownloadCache
    private let check: () throws -> Bool
    private var enabled = false
    private var started = false
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var downloadTask: Task<Void, Never>?
    private var generation = 0

    init(settings: UpdateSettings, cache: UpdateDownloadCache, check: @escaping () throws -> Bool) {
        self.settings = settings
        self.cache = cache
        self.check = check
    }

    func start() {
        guard !started else { return }
        started = true
        settings.$automaticallyCheckForUpdates.dropFirst().sink { [weak self] enabled in
            self?.configure(enabled: enabled)
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.checkIfDue() }
            }.store(in: &subscriptions)
        configure(enabled: settings.automaticallyCheckForUpdates)
    }

    private func configure(enabled: Bool) {
        self.enabled = enabled
        generation += 1
        downloadTask?.cancel()
        downloadTask = nil
        timer?.invalidate()
        timer = nil
        bannerDismissed = false
        status = .idle
        guard enabled else { return }
        let currentGeneration = generation
        Task { [weak self, cache] in
            let cached = await cache.existingDownload()
            guard let self, self.enabled, self.generation == currentGeneration else { return }
            self.cachedUpdate = cached
            if let cached { self.status = .ready(cached.update.displayVersion) }
            self.checkIfDue()
        }
    }

    func checkIfDue(now: Date = Date()) {
        guard enabled else { return }
        defer { scheduleNextCheck(now: now) }
        guard downloadTask == nil, status != .checking,
              UpdateSettings.isDue(lastCheck: settings.lastCheckDate, now: now) else { return }
        do {
            // A manual Sparkle session may be open. Retry later without counting
            // a check that never happened against the daily limit.
            guard try check() else { return }
            settings.markCheckedNow(date: now)
            if cachedUpdate == nil { status = .checking }
        } catch {
            settings.markCheckedNow(date: now)
            updateLogger.error("Automatic update check could not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleNextCheck(now: Date) {
        timer?.invalidate()
        let next = (settings.lastCheckDate ?? now.addingTimeInterval(-UpdateSettings.automaticCheckInterval))
            .addingTimeInterval(UpdateSettings.automaticCheckInterval)
        let interval = max(60, next.timeIntervalSince(now))
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        timer.tolerance = min(60, interval / 10)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func foundUpdate(_ update: UpdateDownload) {
        guard enabled else { return }
        generation += 1
        let currentGeneration = generation
        downloadTask?.cancel()
        status = .downloading(update.displayVersion)
        bannerDismissed = false
        downloadTask = Task { [weak self, cache] in
            do {
                let cached = try await cache.prepare(update)
                guard let self, !Task.isCancelled, self.enabled, self.generation == currentGeneration else { return }
                self.cachedUpdate = cached
                self.status = .ready(update.displayVersion)
                self.downloadTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.enabled, self.generation == currentGeneration else { return }
                // A failed prefetch never blocks the standard manual updater.
                self.status = .available(update.displayVersion)
                self.downloadTask = nil
                updateLogger.error("Update prefetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func foundInformationalUpdate(version: String) {
        guard enabled else { return }
        status = .available(version)
        bannerDismissed = false
    }

    func finishedChecking() {
        if status == .checking { status = .idle }
    }

    func prepareForManualUpdate() {
        generation += 1
        downloadTask?.cancel()
        downloadTask = nil
        status = cachedUpdate.map { .ready($0.update.displayVersion) } ?? .idle
        bannerDismissed = true
    }

    func invalidateCachedUpdate() {
        guard let cached = cachedUpdate else { return }
        cachedUpdate = nil
        if enabled { status = .available(cached.update.displayVersion) }
        Task { [cache] in await cache.discard(cached) }
    }

    func clearAvailableUpdate() {
        generation += 1
        downloadTask?.cancel()
        downloadTask = nil
        invalidateCachedUpdate()
        status = .idle
        bannerDismissed = true
    }

    func dismissBanner() { bannerDismissed = true }
}
