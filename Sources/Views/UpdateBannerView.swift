import SwiftUI

/// An unobtrusive banner shown when the opt-in once-a-day background check finds
/// a newer release. Mirrors `AudioDetectionBanner`'s styling. Manual checks use an
/// `NSAlert` instead — this is only the quiet automatic path.
struct UpdateBannerView: View {
    let versionTitle: String
    let onDownload: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(SeminarlyColors.accent)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Update available")
                    .font(Typography.headline)
                    .foregroundStyle(SeminarlyColors.textPrimary)
                    .lineLimit(1)
                Text("\(versionTitle) is ready to download")
                    .font(Typography.caption)
                    .foregroundStyle(SeminarlyColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onDownload()
            } label: {
                Text("Download")
                    .font(Typography.captionMedium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(SeminarlyColors.accent, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Open the release page to download the update")

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
