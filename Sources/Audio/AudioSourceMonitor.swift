import AudioToolbox
import Foundation
import os.log

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "AudioSourceMonitor")

/// Monitors for new audio-producing processes and prompts the user to start recording.
/// Polls the Core Audio process list every 3 seconds and detects transitions from silent → active.
@MainActor
final class AudioSourceMonitor: ObservableObject {
    @Published var detectedProcess: AudioProcess?
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                startMonitoring()
            } else {
                stopMonitoring()
                detectedProcess = nil
            }
        }
    }

    /// Set to true while a recording is active — suppresses new detections.
    var isRecordingActive = false {
        didSet {
            if isRecordingActive {
                detectedProcess = nil
                bannerDismissTask?.cancel()
            }
        }
    }

    private static let enabledKey = "autoDetectAudioSources"
    private static let pollInterval: TimeInterval = 3.0
    private static let bannerTimeout: TimeInterval = 20.0

    /// Bundle IDs of known meeting/conferencing apps (prioritized for detection).
    private static let meetingBundleIDs: Set<String> = [
        "us.zoom.xos",
        "us.zoom.CptHost",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.apple.FaceTime",
        "com.webex.meetingmanager",
        "com.cisco.webexmeetingsapp",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser",
        "com.loom.desktop",
        "com.pop.pop.app",
        "com.riverside.app",
    ]

    /// Bundle IDs to ignore (our own app, system processes).
    private static let ignoredBundleIDs: Set<String> = [
        "ai.seminarly.Seminarly",
        "com.apple.controlcenter",
        "com.apple.SystemSounds",
        "com.apple.finder",
        "com.apple.notificationcenterui",
    ]

    private var pollTimer: Timer?
    /// Tracks which process objectIDs were running output in the last poll.
    private var knownActiveObjectIDs: Set<AudioObjectID> = []
    /// Bundle IDs the user dismissed — don't re-suggest in this monitoring session.
    private var dismissedBundleIDs: Set<String> = []
    private var bannerDismissTask: Task<Void, Never>?

    init() {
        self.isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func startMonitoring() {
        guard isEnabled else { return }
        stopMonitoring()
        seedCurrentState()

        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        logger.info("Audio source monitoring started")
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
    }

    func dismiss() {
        if let process = detectedProcess {
            if let bundleID = process.bundleID {
                dismissedBundleIDs.insert(bundleID)
            }
        }
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        detectedProcess = nil
    }

    func accept() -> AudioProcess? {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        let process = detectedProcess
        detectedProcess = nil
        return process
    }

    /// Re-seed state after recording stops so apps that started during recording don't immediately trigger.
    func reseedAfterRecording() {
        isRecordingActive = false
        dismissedBundleIDs.removeAll()
        seedCurrentState()
    }

    // MARK: - Private

    private func seedCurrentState() {
        do {
            let processes = try CoreAudioUtils.listAudioProcesses()
            knownActiveObjectIDs = Set(
                processes.filter(\.isRunningOutput).map(\.objectID)
            )
        } catch {
            knownActiveObjectIDs = []
        }
    }

    private func poll() {
        guard isEnabled, !isRecordingActive else { return }

        do {
            let processes = try CoreAudioUtils.listAudioProcesses()
            let currentlyActive = processes.filter(\.isRunningOutput)
            let currentlyActiveIDs = Set(currentlyActive.map(\.objectID))

            // Find newly active objectIDs
            let newlyActiveIDs = currentlyActiveIDs.subtracting(knownActiveObjectIDs)
            knownActiveObjectIDs = currentlyActiveIDs

            guard !newlyActiveIDs.isEmpty, detectedProcess == nil else { return }

            // Filter candidates
            let candidates = currentlyActive.filter { process in
                guard newlyActiveIDs.contains(process.objectID) else { return false }
                if let bundleID = process.bundleID {
                    if Self.ignoredBundleIDs.contains(bundleID) { return false }
                    if dismissedBundleIDs.contains(bundleID) { return false }
                }
                return true
            }

            // Prefer meeting apps over generic audio sources
            let meetingApp = candidates.first { process in
                guard let bundleID = process.bundleID else { return false }
                return Self.meetingBundleIDs.contains(bundleID)
            }

            if let best = meetingApp ?? candidates.first {
                logger.info("Detected new audio source: \(best.name) (\(best.bundleID ?? "unknown"))")
                detectedProcess = best
                scheduleBannerDismiss()
            }
        } catch {
            logger.error("Failed to poll audio processes: \(error.localizedDescription)")
        }
    }

    private func scheduleBannerDismiss() {
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.bannerTimeout))
            guard !Task.isCancelled else { return }
            detectedProcess = nil
        }
    }
}
