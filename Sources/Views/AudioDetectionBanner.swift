import SwiftUI
import AppKit

/// Banner that appears when a new audio-producing app is detected,
/// prompting the user to start recording.
struct AudioDetectionBanner: View {
    let process: AudioProcess
    let onRecord: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // App icon
            if let icon = process.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(SeminarlyColors.accent)
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(Typography.headline)
                    .foregroundStyle(SeminarlyColors.textPrimary)
                    .lineLimit(1)
                Text("is producing audio")
                    .font(Typography.caption)
                    .foregroundStyle(SeminarlyColors.textSecondary)
            }

            Spacer()

            Button {
                onRecord()
            } label: {
                Text("Record")
                    .font(Typography.captionMedium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(SeminarlyColors.accent, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SeminarlyColors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .seminarlyCard()
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}
