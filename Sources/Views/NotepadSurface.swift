import SwiftUI

/// Shared notepad surface that renders either an editable markdown editor
/// (when `structuredNote` is nil) or a read-only structured view with
/// user-sourced items rendered first within each section.
///
/// Used by `RecordingView` (post-stop, pre/post-enhancement) and
/// `MeetingDetailView` to keep the notepad visually continuous across the
/// meeting lifecycle.
struct NotepadSurface: View {
    @Binding var userNotesText: String
    let structuredNote: StructuredNote?
    var isEditable: Bool = true
    var autoFocus: Bool = false
    var placeholderTitle: String = "Type your notes here..."
    var placeholderSubtitle: String? = "Use # headings to define sections"
    var onLineCompleted: ((String) -> Void)? = nil
    var onTranscriptRefTap: ((String) -> Void)? = nil

    var body: some View {
        if let note = structuredNote {
            enhancedView(note: note)
        } else {
            editorView
        }
    }

    // MARK: - Editor Mode (pre-enhancement)

    private var editorView: some View {
        ZStack(alignment: .topLeading) {
            MarkdownNoteEditor(
                text: $userNotesText,
                isEditable: isEditable,
                fontSize: 14,
                autoFocus: autoFocus,
                onLineCompleted: onLineCompleted
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if userNotesText.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(placeholderTitle)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(SeminarlyColors.textTertiary)
                    if let subtitle = placeholderSubtitle {
                        Text(subtitle)
                            .font(Typography.caption)
                            .foregroundStyle(SeminarlyColors.textTertiary.opacity(0.7))
                    }
                }
                .padding(.leading, 12 + 5) // textContainerInset.width + lineFragmentPadding
                .padding(.top, 12)          // textContainerInset.height
                .allowsHitTesting(false)
            }
        }
        .background(SeminarlyColors.background)
    }

    // MARK: - Enhanced Mode (post-enhancement)

    private func enhancedView(note: StructuredNote) -> some View {
        // Sort items once per render outside ForEach to avoid per-row re-allocation
        let sortedSections = note.sections.map { section in
            (section: section, items: sortedBySource(section.items))
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if !note.summary.isEmpty {
                    summarySection(summary: note.summary)
                }

                templateBadge(template: note.resolvedTemplate)

                ForEach(sortedSections, id: \.section.key) { entry in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Label(entry.section.title, systemImage: entry.section.icon)
                            .font(Typography.headline)
                            .foregroundStyle(SeminarlyColors.textPrimary)

                        ForEach(entry.items, id: \.self) { item in
                            BulletPoint(item: item, onTranscriptRefTap: onTranscriptRefTap)
                        }
                    }
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summarySection(summary: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Summary", systemImage: "text.alignleft")
                .font(Typography.headline)
                .foregroundStyle(SeminarlyColors.textPrimary)
            Text(summary)
                .font(Typography.body)
                .foregroundStyle(SeminarlyColors.textPrimary)
        }
    }

    private func templateBadge(template: NoteTemplate) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: template.icon)
            Text(template.displayName)
        }
        .font(Typography.captionMedium)
        .foregroundStyle(SeminarlyColors.textSecondary)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(SeminarlyColors.surface, in: Capsule())
    }

    /// User-sourced items first (treating legacy nil as user), transcript-sourced after.
    /// Preserves relative order within each group. Children are sorted recursively
    /// so sub-bullets within a parent are also grouped by source.
    private func sortedBySource(_ items: [NoteItem]) -> [NoteItem] {
        var userItems: [NoteItem] = []
        var transcriptItems: [NoteItem] = []
        for item in items {
            let rebuilt: NoteItem
            if let children = item.children, !children.isEmpty {
                rebuilt = NoteItem(
                    text: item.text,
                    source: item.source,
                    transcriptRef: item.transcriptRef,
                    children: sortedBySource(children)
                )
            } else {
                rebuilt = item
            }
            if rebuilt.source == .transcript {
                transcriptItems.append(rebuilt)
            } else {
                userItems.append(rebuilt)
            }
        }
        return userItems + transcriptItems
    }
}
