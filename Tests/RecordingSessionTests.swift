import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Seminarly

final class RecordingSessionTests: XCTestCase {
    @MainActor
    private final class TestClock {
        var time: TimeInterval = 100
    }

    @MainActor
    private func makeSession(clock: TestClock) throws -> (RecordingSession, ModelContainer) {
        let config = ModelConfiguration(schema: SeminarlyApp.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SeminarlyApp.schema, configurations: [config])
        let capture = AudioCaptureManager()
        // Exercise the real asynchronous capture lifecycle without opening any
        // audio device, requesting permissions, or downloading speech models.
        capture.captureMicrophone = false
        let session = RecordingSession(
            captureManager: capture,
            transcriptionEngine: TranscriptionEngine(),
            diarizationEngine: NeuralDiarizationEngine(),
            now: { clock.time }
        )
        return (session, container)
    }

    @MainActor
    private func waitForCapture(_ session: RecordingSession) async throws {
        for _ in 0..<100 {
            if session.isRecording { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Capture did not start")
    }

    @MainActor
    private func makeWindow(session: RecordingSession, container: ModelContainer) -> NSWindow {
        let view = RecordingView(
            selectedMeeting: .constant(nil),
            captureManager: session.captureManager,
            session: session,
            transcriptionEngine: session.transcriptionEngine,
            diarizationEngine: session.diarizationEngine,
            audioMonitor: AudioSourceMonitor()
        )
        .environment(AppState(recordingSession: session))
        .modelContainer(container)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        return window
    }

    @MainActor
    func testRecordingSurvivesMinimizeCloseAndReopenWithSameNotesAndTranscript() async throws {
        let clock = TestClock()
        let (session, container) = try makeSession(clock: clock)
        let appState = AppState(recordingSession: session)
        session.userNotesText = "Agenda before recording"
        session.startRecording(modelContext: container.mainContext)
        try await waitForCapture(session)
        session.transcriptionEngine.liveText = "Before closing the window"
        let id = session.id

        let window = makeWindow(session: session, container: container)
        window.makeKeyAndOrderFront(nil)
        await Task.yield()
        window.miniaturize(nil)
        clock.time += 90
        session.updateElapsedTime()
        XCTAssertTrue(session.isRecording)
        XCTAssertTrue(session.hasBackgroundActivity)
        XCTAssertEqual(appState.recordingElapsedTime, 90)

        window.close()
        window.contentView = nil
        await Task.yield()
        clock.time += 60
        session.updateElapsedTime()
        XCTAssertTrue(appState.isRecording)
        XCTAssertTrue(session.transcriptionEngine.isSessionActive)
        XCTAssertNil(session.savedMeeting)
        XCTAssertTrue(session.shouldRestoreRecording)

        let reopened = makeWindow(session: appState.recordingSession, container: container)
        reopened.makeKeyAndOrderFront(nil)
        await Task.yield()
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.elapsedTime, 150)
        XCTAssertEqual(session.userNotesText, "Agenda before recording")
        XCTAssertEqual(session.transcriptionEngine.liveText, "Before closing the window")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Meeting>()), 0)
        reopened.close()
        reopened.contentView = nil

        let save = try XCTUnwrap(session.stopRecording())
        XCTAssertNil(session.stopRecording(), "A second window must not start a second save")
        await save.value
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Meeting>()), 1)
        XCTAssertEqual(session.savedMeeting?.duration, 150)
        XCTAssertEqual(session.savedMeeting?.userNotesText, "Agenda before recording")
        XCTAssertEqual(session.savedMeeting?.transcript?.rawText, "Before closing the window")
        XCTAssertFalse(session.hasBackgroundActivity)
    }

    @MainActor
    func testDelayedTimerAndExplicitPauseExcludeOnlyPausedTime() async throws {
        let clock = TestClock()
        let (session, container) = try makeSession(clock: clock)
        session.startRecording(modelContext: container.mainContext)
        try await waitForCapture(session)
        clock.time += 127.5
        session.updateElapsedTime()
        XCTAssertEqual(session.elapsedTime, 127.5)

        session.pauseRecording()
        XCTAssertTrue(session.isPaused)
        XCTAssertFalse(session.hasBackgroundActivity)
        clock.time += 600
        session.updateElapsedTime()
        XCTAssertEqual(session.elapsedTime, 127.5)

        session.resumeRecording()
        try await waitForCapture(session)
        XCTAssertTrue(session.hasBackgroundActivity)
        clock.time += 32.5
        await session.stopRecording()?.value
        XCTAssertEqual(session.savedMeeting?.duration, 160)
        XCTAssertFalse(session.transcriptionEngine.isSessionActive)
        XCTAssertFalse(session.hasBackgroundActivity)
    }

    @MainActor
    func testTerminationSavesWithoutAnyRecordingView() async throws {
        let clock = TestClock()
        let (session, container) = try makeSession(clock: clock)
        session.userNotesText = "Background session"
        session.startRecording(modelContext: container.mainContext)
        try await waitForCapture(session)
        clock.time += 20
        session.stopForTermination()
        XCTAssertTrue(session.isProcessingNotes)
        XCTAssertTrue(session.hasBackgroundActivity)
        for _ in 0..<100 {
            if !session.ownsRecordingSession { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(session.ownsRecordingSession)
        XCTAssertFalse(session.hasBackgroundActivity)
        XCTAssertEqual(session.savedMeeting?.duration, 20)
        XCTAssertEqual(session.savedMeeting?.userNotesText, "Background session")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Meeting>()), 1)
    }

    @MainActor
    func testStopDuringStartupCannotResurrectCaptureOrLeaveAnActivity() async throws {
        let clock = TestClock()
        let (session, container) = try makeSession(clock: clock)
        session.startRecording(modelContext: container.mainContext)
        session.stopForTermination()
        // The detached Core Audio task must observe its invalidated generation.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.transcriptionEngine.isSessionActive)
        XCTAssertFalse(session.hasBackgroundActivity)
        XCTAssertNil(session.savedMeeting)
    }

    @MainActor
    func testCaptureStartFailureReleasesSessionWithoutAViewAndCanRetry() async throws {
        let clock = TestClock()
        let (session, container) = try makeSession(clock: clock)
        session.startRecording(modelContext: container.mainContext)
        session.captureManager.state = .error("Test startup failure")
        XCTAssertFalse(session.ownsRecordingSession)
        XCTAssertFalse(session.hasBackgroundActivity)
        XCTAssertFalse(session.transcriptionEngine.isSessionActive)
        XCTAssertEqual(session.captureManager.state, .error("Test startup failure"))

        session.startRecording(modelContext: container.mainContext)
        try await waitForCapture(session)
        XCTAssertTrue(session.hasBackgroundActivity)
        await session.stopRecording()?.value
        XCTAssertNotNil(session.savedMeeting)
    }

    @MainActor
    func testCaptureFailureAfterStartupSavesOnceWithoutAView() async throws {
        let clock = TestClock()
        let (session, container) = try makeSession(clock: clock)
        session.startRecording(modelContext: container.mainContext)
        try await waitForCapture(session)
        session.transcriptionEngine.liveText = "Audio before device failure"
        clock.time += 45
        session.captureManager.state = .error("Test device failure")
        XCTAssertTrue(session.isProcessingNotes)
        XCTAssertTrue(session.hasBackgroundActivity)
        for _ in 0..<100 {
            if !session.ownsRecordingSession { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.savedMeeting?.duration, 45)
        XCTAssertEqual(session.savedMeeting?.transcript?.rawText, "Audio before device failure")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Meeting>()), 1)
        XCTAssertFalse(session.hasBackgroundActivity)
    }

    @MainActor
    func testNewRecordingCannotResetAnActiveOrSavingSession() async throws {
        let clock = TestClock()
        let (session, container) = try makeSession(clock: clock)
        session.userNotesText = "Keep these notes"
        session.startRecording(modelContext: container.mainContext)
        try await waitForCapture(session)
        let id = session.id
        session.prepareNewRecording()
        session.startRecording(modelContext: container.mainContext)
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.userNotesText, "Keep these notes")
        let save = try XCTUnwrap(session.stopRecording())
        session.prepareNewRecording()
        session.startRecording(modelContext: container.mainContext)
        XCTAssertEqual(session.id, id)
        await save.value

        session.prepareNewRecording()
        XCTAssertNotEqual(session.id, id)
        XCTAssertTrue(session.userNotesText.isEmpty)
        XCTAssertNil(session.savedMeeting)
        XCTAssertTrue(session.isInSetupPhase)
    }

    @MainActor
    func testClosingLastWindowDoesNotQuitApp() {
        XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(.shared))
    }
}
