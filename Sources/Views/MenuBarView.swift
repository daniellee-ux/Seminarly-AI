import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            if appState.isRecording {
                Button {
                    // Open main window to stop recording
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if let window = NSApplication.shared.windows.first(where: { $0.title.contains("Seminarly") || $0.isKeyWindow }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                } label: {
                    Label("Recording in progress...", systemImage: "record.circle.fill")
                        .foregroundStyle(SeminarlyColors.recording)
                }
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
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        // No window left (user closed the last one) — create a fresh one.
        openWindow(id: SeminarlyApp.mainWindowID)
    }
}
