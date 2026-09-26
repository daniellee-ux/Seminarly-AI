import SwiftUI

/// Quiet background download status. Installation opens Sparkle for confirmation.
struct UpdateBannerView: View {
    let versionTitle: String
    let isDownloading: Bool
    let isDownloaded: Bool
    let onInstall: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(SeminarlyColors.accent)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(isDownloading ? "Downloading update…" : isDownloaded ? "Update downloaded" : "Update available")
                    .font(Typography.headline)
                    .foregroundStyle(SeminarlyColors.textPrimary)
                    .lineLimit(1)
                Text(isDownloaded ? "Version \(versionTitle) is ready to install" : "Version \(versionTitle)")
                    .font(Typography.caption)
                    .foregroundStyle(SeminarlyColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if isDownloading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    onInstall()
                } label: {
                    Text(isDownloaded ? "Install Update…" : "View Update…")
                        .font(Typography.captionMedium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxs)
                        .background(SeminarlyColors.accent, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Review the update and confirm installation in Seminarly")
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SeminarlyColors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .seminarlyCard()
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}
