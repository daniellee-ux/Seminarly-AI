import SwiftUI
import SwiftData
import AppKit

/// Full-window blocking error screen shown when the primary SwiftData store could not
/// be opened and the app is running on an in-memory container. Prevents the user from
/// reaching the recording UI (where writes would silently evaporate on quit) and
/// funnels them into Restore / Start Fresh / Quit.
struct DatabaseErrorView: View {
    @Environment(DatabaseState.self) private var databaseState
    @State private var isRestoring = false
    @State private var restoreFailed = false

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer(minLength: 0)

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)

            VStack(spacing: Spacing.sm) {
                Text("Unable to Open Database")
                    .font(Typography.title)
                    .foregroundStyle(SeminarlyColors.textPrimary)

                Text(messageText)
                    .font(Typography.body)
                    .foregroundStyle(SeminarlyColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)

                if let underlying = underlyingErrorText {
                    Text(underlying)
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, Spacing.xs)
                        .frame(maxWidth: 520)
                }
            }

            if restoreFailed {
                Text("Restore from backup failed — no usable backups found. Try Start Fresh or Quit.")
                    .font(Typography.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            VStack(spacing: Spacing.sm) {
                Button {
                    Task { await restoreFromBackup() }
                } label: {
                    Label("Restore from Backup", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRestoring)

                Button(role: .destructive) {
                    confirmAndStartFresh()
                } label: {
                    Label("Start Fresh", systemImage: "trash")
                        .frame(maxWidth: 260)
                }
                .controlSize(.large)
                .disabled(isRestoring)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .frame(maxWidth: 260)
                }
                .controlSize(.large)
                .disabled(isRestoring)
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SeminarlyColors.background)
    }

    private var messageText: String {
        "Your recordings and notes are not lost — the on-disk database files have been preserved. Choose an option below to continue."
    }

    private var underlyingErrorText: String? {
        guard case let .failedToOpen(underlying) = databaseState.error else { return nil }
        return "Technical details: \(underlying)"
    }

    private var storeURL: URL {
        AppDelegate.storeURL
    }

    @MainActor
    private func restoreFromBackup() async {
        isRestoring = true
        defer { isRestoring = false }

        let succeeded = SeminarlyApp.restoreLatestBackup(to: storeURL)
        if succeeded {
            NSApplication.shared.terminate(nil)
        } else {
            restoreFailed = true
        }
    }

    private func confirmAndStartFresh() {
        let alert = NSAlert()
        alert.messageText = "Start Fresh?"
        alert.informativeText = "This deletes the current database file. Existing backups are kept. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete and Restart")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            SeminarlyApp.deleteStoreAndRestart(storeURL: storeURL)
            NSApplication.shared.terminate(nil)
        }
    }
}
