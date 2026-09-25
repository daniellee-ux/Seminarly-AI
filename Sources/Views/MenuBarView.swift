import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            if appState.isRecording {
                Button {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openMainWindow()
                    NotificationCenter.default.post(name: .seminarlyShowRecording, object: nil)
                } label: {
                    Label(appState.isPaused ? "Recording paused" : "Recording in progress...", systemImage: "record.circle.fill")
                        .foregroundStyle(SeminarlyColors.recording)
                }

                Button(appState.isPaused ? "Resume Recording" : "Pause Recording") {
                    if appState.isPaused {
                        appState.recordingSession.resumeRecording()
                    } else {
                        appState.recordingSession.pauseRecording()
                    }
                }
                Button("Stop Recording") {
                    appState.recordingSession.stopRecording()
                }
                Divider()
            }

            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openMainWindow()
            } label: {
                Label("Open Seminarly", systemImage: "waveform.circle.fill")
            }
            .keyboardShortcut("o")

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func openMainWindow() {
        for window in NSApplication.shared.windows {
            if window.title == "Seminarly" || window.canBecomeMain {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        // No window left (user closed the last one) — create a fresh one.
        openWindow(id: SeminarlyApp.mainWindowID)
    }
}
