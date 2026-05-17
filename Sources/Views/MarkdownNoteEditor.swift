import SwiftUI
import AppKit

// MARK: - List Prefix Parsing (file-scope, testable)

struct ListPrefix: Equatable {
    let leadingWhitespace: String
    let marker: Marker
    /// Length of the full prefix (leadingWhitespace + marker + trailing space) in NSString/UTF-16 units.
    let prefixLength: Int
}

enum Marker: Equatable {
    case bullet(Character)          // "-" or "*"
    case numbered(Int)
    case checkbox(checked: Bool)
}

/// Parses a single line of text (no trailing newline) for a list marker prefix.
/// Order: checkbox → bullet → numbered. Returns nil if no list prefix matches.
func parseListPrefix(_ line: String) -> ListPrefix? {
    // Walk leading whitespace (spaces + tabs)
    var idx = line.startIndex
    while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
        idx = line.index(after: idx)
    }
    let leadingWhitespace = String(line[line.startIndex..<idx])
    let rest = line[idx...]
    guard !rest.isEmpty else { return nil }

    // Checkbox FIRST (must precede bullet, since "- [ ] " starts with "- ")
    if rest.hasPrefix("- [ ] ") {
        let prefix = leadingWhitespace + "- [ ] "
        return ListPrefix(
            leadingWhitespace: leadingWhitespace,
            marker: .checkbox(checked: false),
            prefixLength: (prefix as NSString).length
        )
    }
    if rest.hasPrefix("- [x] ") || rest.hasPrefix("- [X] ") {
        let prefix = leadingWhitespace + "- [x] "
        return ListPrefix(
            leadingWhitespace: leadingWhitespace,
            marker: .checkbox(checked: true),
            prefixLength: (prefix as NSString).length
        )
    }

    // Bullet
    if rest.hasPrefix("- ") {
        let prefix = leadingWhitespace + "- "
        return ListPrefix(
            leadingWhitespace: leadingWhitespace,
            marker: .bullet("-"),
            prefixLength: (prefix as NSString).length
        )
    }
    if rest.hasPrefix("* ") {
        let prefix = leadingWhitespace + "* "
        return ListPrefix(
            leadingWhitespace: leadingWhitespace,
            marker: .bullet("*"),
            prefixLength: (prefix as NSString).length
        )
    }

    // Numbered: one or more digits, then ". "
    var numEnd = idx
    while numEnd < line.endIndex, line[numEnd].isNumber {
        numEnd = line.index(after: numEnd)
    }
    guard numEnd > idx else { return nil }
    guard numEnd < line.endIndex, line[numEnd] == "." else { return nil }
    let afterDot = line.index(after: numEnd)
    guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
    let numberStr = String(line[idx..<numEnd])
    guard let n = Int(numberStr) else { return nil }
    let prefix = leadingWhitespace + numberStr + ". "
    return ListPrefix(
        leadingWhitespace: leadingWhitespace,
        marker: .numbered(n),
        prefixLength: (prefix as NSString).length
    )
}

/// Returns the marker text to insert on the next line when Enter is pressed
/// on a list line. Leading whitespace is NOT included.
func nextLineContinuation(for prefix: ListPrefix) -> String {
    switch prefix.marker {
    case .bullet(let char):
        return "\(char) "
    case .numbered(let n):
        return "\(n + 1). "
    case .checkbox:
        return "- [ ] "
    }
}

/// Returns the literal marker text of an existing prefix (for measuring font width).
/// Leading whitespace is NOT included.
func markerString(for prefix: ListPrefix) -> String {
    switch prefix.marker {
    case .bullet(let char):
        return "\(char) "
    case .numbered(let n):
        return "\(n). "
    case .checkbox(let checked):
        return checked ? "- [x] " : "- [ ] "
    }
}

/// Result of transforming a block of lines for indent/outdent operations.
struct BlockIndentResult: Equatable {
    let lines: [String]
    let firstLineDelta: Int
    let totalDelta: Int
}

/// Transforms a block of lines by indenting (`outdent: false`) or outdenting
/// (`outdent: true`) each by two spaces. Numbered list items are renumbered
/// based on sibling context (both `contextLines` before the block and prior
/// transformed lines within the block). Bullets/checkboxes preserve their
/// marker. Non-list lines get plain indent/outdent.
func transformBlockIndent(
    lines: [String],
    contextLines: [String],
    outdent: Bool
) -> BlockIndentResult {
    let indentUnit = "  "
    var running = contextLines
    var transformed: [String] = []
    var firstLineDelta = 0
    var totalDelta = 0

    for (idx, line) in lines.enumerated() {
        let newLine: String
        if let prefix = parseListPrefix(line) {
            let oldIndent = prefix.leadingWhitespace
            let newIndent: String
            if outdent {
                if oldIndent.hasPrefix(indentUnit) {
                    newIndent = String(oldIndent.dropFirst(indentUnit.count))
                } else if oldIndent.hasPrefix("\t") {
                    newIndent = String(oldIndent.dropFirst(1))
                } else {
                    newIndent = oldIndent
                }
            } else {
                newIndent = oldIndent + indentUnit
            }
            let lineNS = line as NSString
            let content =
                prefix.prefixLength < lineNS.length
                ? lineNS.substring(from: prefix.prefixLength)
                : ""
            let newMarker: String
            if case .numbered = prefix.marker {
                let n = computeNumberForIndent(
                    lines: running,
                    currentLineIndex: running.count,
                    targetIndent: newIndent
                )
                newMarker = "\(n). "
            } else {
                newMarker = markerString(for: prefix)
            }
            newLine = newIndent + newMarker + content
        } else {
            if outdent {
                if line.hasPrefix(indentUnit) {
                    newLine = String(line.dropFirst(indentUnit.count))
                } else if line.hasPrefix("\t") {
                    newLine = String(line.dropFirst(1))
                } else {
                    newLine = line
                }
            } else {
                newLine = indentUnit + line
            }
        }
        let delta = (newLine as NSString).length - (line as NSString).length
        transformed.append(newLine)
        running.append(newLine)
        if idx == 0 { firstLineDelta = delta }
        totalDelta += delta
    }

    return BlockIndentResult(
        lines: transformed,
        firstLineDelta: firstLineDelta,
        totalDelta: totalDelta
    )
}

/// Computes the number to use for a numbered list item at `targetIndent`,
/// based on preceding siblings in `lines[0..<currentLineIndex]`. Walks backwards:
/// returns N+1 if a sibling at the same indent is numbered(N); returns 1 if it
/// hits a shallower indent (parent scope changes) or a non-numbered sibling,
/// or walks off the start of the document.
func computeNumberForIndent(
    lines: [String],
    currentLineIndex: Int,
    targetIndent: String
) -> Int {
    let targetLen = (targetIndent as NSString).length
    var i = currentLineIndex - 1
    while i >= 0 {
        var line = lines[i]
        if line.hasSuffix("\r") { line.removeLast() }
        if let prefix = parseListPrefix(line) {
            let prefixLen = (prefix.leadingWhitespace as NSString).length
            if prefixLen < targetLen {
                return 1  // hit a shallower (parent) scope
            }
            if prefix.leadingWhitespace == targetIndent {
                if case .numbered(let n) = prefix.marker {
                    return n + 1
                }
                return 1  // sibling at same level but not numbered
            }
            // Deeper nested sibling — walk past
        }
        // Non-list line — transparent, walk past
        i -= 1
    }
    return 1
}

// MARK: - NSTextView Subclass

@MainActor
final class MarkdownTextView: NSTextView {
    weak var coordinator: MarkdownNoteEditor.Coordinator?

    override func insertNewline(_ sender: Any?) {
        // IME composition: let the system handle newline
        if hasMarkedText() {
            super.insertNewline(sender)
            return
        }
        if coordinator?.handleNewline(in: self) == true {
            return
        }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if hasMarkedText() {
            super.insertTab(sender)
            return
        }
        if coordinator?.handleTab(in: self, outdent: false) == true {
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if hasMarkedText() {
            super.insertBacktab(sender)
            return
        }
        if coordinator?.handleTab(in: self, outdent: true) == true {
            return
        }
        super.insertBacktab(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only intercept plain Cmd-B / Cmd-I (no shift/opt/ctrl)
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let active = event.modifierFlags.intersection(relevant)
        if active == .command, let chars = event.charactersIgnoringModifiers {
            if chars == "b" {
                coordinator?.wrapSelection(in: self, with: "**")
                return true
            }
            if chars == "i" {
                coordinator?.wrapSelection(in: self, with: "*")
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            super.mouseDown(with: event)
            return
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        let adjusted = NSPoint(
            x: localPoint.x - textContainerInset.width,
            y: localPoint.y - textContainerInset.height
        )
        let charIndex = layoutManager.characterIndex(
            for: adjusted,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        if coordinator?.handleCheckboxClick(in: self, at: charIndex) == true {
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - MarkdownNoteEditor

/// NSTextView-backed editor with live markdown styling for headings, bold, lists, and checkboxes.
/// Used in RecordingView (notepad) and MeetingDetailView (post-recording notes editor).
struct MarkdownNoteEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var fontSize: CGFloat = 14
    var autoFocus: Bool = false
    var onLineCompleted: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
        let textView = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height)
        )
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = EditorColors.text
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)

        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator

        scrollView.documentView = textView

        if !text.isEmpty {
            textView.string = text
            context.coordinator.applyMarkdownStyling(to: textView)
        }

        context.coordinator.previousLineCount = text.components(separatedBy: "\n").count

        if autoFocus {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard !context.coordinator.isUpdatingFromTextView else { return }
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }

        textView.coordinator = context.coordinator  // re-attach on SwiftUI view-identity churn
        textView.isEditable = isEditable

        // IME composition: `textDidChange` skips updating `parent.text` while
        // marked text is active, so during composition `textView.string`
        // (committed + marked) differs from `text` (committed only). Skipping
        // here is essential — without it, the sync below would assign
        // `textView.string = text`, wipe the marked text mid-composition, and
        // break Zhuyin/Cangjie/Pinyin (the user can never reach the Enter that
        // commits the character). RecordingView's 1s timer ticks this every
        // second during recording. Reconciliation happens on the next
        // `textDidChange` once composition ends.
        if textView.hasMarkedText() { return }

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            context.coordinator.applyMarkdownStyling(to: textView)
            let length = (textView.string as NSString).length
            let validRanges = selectedRanges.filter {
                let range = $0.rangeValue
                return range.location + range.length <= length
            }
            if !validRanges.isEmpty {
                textView.selectedRanges = validRanges
            }
            context.coordinator.previousLineCount = text.components(separatedBy: "\n").count
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownNoteEditor
        var isUpdatingFromTextView = false
        var isApplyingStyling = false
        var previousLineCount: Int = 0

        init(parent: MarkdownNoteEditor) {
            self.parent = parent
        }

        nonisolated func textDidChange(_ notification: Notification) {
            // NSTextViewDelegate is always called on main thread
            let textView = notification.object as! NSTextView
            MainActor.assumeIsolated {
                handleTextDidChange(textView)
            }
        }

        private func handleTextDidChange(_ textView: NSTextView) {
            guard !isApplyingStyling else { return }

            // Skip updates while IME composition is active (e.g. Zhuyin, Cangjie)
            if textView.hasMarkedText() { return }

            let newText = textView.string
            let newLineCount = newText.components(separatedBy: "\n").count

            // Detect Enter keypress — timestamp the completed line
            if newLineCount > previousLineCount, let onLineCompleted = parent.onLineCompleted {
                let lines = newText.components(separatedBy: "\n")
                let completedIndex = newLineCount - 2
                if completedIndex >= 0 && completedIndex < lines.count {
                    let completedText = lines[completedIndex]
                        .trimmingCharacters(in: .whitespaces)
                    if !completedText.isEmpty {
                        onLineCompleted(completedText)
                    }
                }
            }
            previousLineCount = newLineCount

            isUpdatingFromTextView = true
            parent.text = newText
            isUpdatingFromTextView = false

            applyMarkdownStyling(to: textView)
        }

        nonisolated func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            true
        }

        // MARK: List continuation (Enter key)

        func handleNewline(in textView: MarkdownTextView) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            let fullText = textView.string as NSString
            let cursorRange = textView.selectedRange
            guard cursorRange.location <= fullText.length else { return false }
            let lineRange = fullText.lineRange(
                for: NSRange(location: cursorRange.location, length: 0)
            )
            var line = fullText.substring(with: lineRange)
            if line.hasSuffix("\n") { line.removeLast() }
            if line.hasSuffix("\r") { line.removeLast() }

            guard let prefix = parseListPrefix(line) else { return false }

            // Content after prefix (in NSString units)
            let lineNS = line as NSString
            let contentAfterPrefix: String =
                prefix.prefixLength < lineNS.length
                    ? lineNS.substring(from: prefix.prefixLength)
                    : ""

            // Empty marker → exit list (delete the prefix, no newline inserted)
            if contentAfterPrefix.trimmingCharacters(in: .whitespaces).isEmpty {
                let prefixAbsRange = NSRange(
                    location: lineRange.location,
                    length: prefix.prefixLength
                )
                guard textView.shouldChangeText(in: prefixAbsRange, replacementString: "")
                else { return true }
                textView.textStorage?.replaceCharacters(in: prefixAbsRange, with: "")
                textView.didChangeText()
                return true
            }

            // Continue list
            let continuation = "\n" + prefix.leadingWhitespace + nextLineContinuation(for: prefix)
            let insertionRange = NSRange(location: cursorRange.location, length: 0)
            guard textView.shouldChangeText(in: insertionRange, replacementString: continuation)
            else { return true }
            textView.textStorage?.replaceCharacters(in: insertionRange, with: continuation)
            textView.didChangeText()
            textView.selectedRange = NSRange(
                location: insertionRange.location + (continuation as NSString).length,
                length: 0
            )
            return true
        }

        // MARK: Indent/outdent (Tab, Shift-Tab)

        func handleTab(in textView: MarkdownTextView, outdent: Bool) -> Bool {
            let fullText = textView.string as NSString
            let selected = textView.selectedRange
            guard selected.location + selected.length <= fullText.length else { return false }

            let indentUnit = "  "
            let indentLen = (indentUnit as NSString).length

            // Branch A: single cursor — only act on list lines
            if selected.length == 0 {
                let lineRange = fullText.lineRange(
                    for: NSRange(location: selected.location, length: 0)
                )
                var line = fullText.substring(with: lineRange)
                if line.hasSuffix("\n") { line.removeLast() }
                if line.hasSuffix("\r") { line.removeLast() }
                guard let prefix = parseListPrefix(line) else { return false }

                let lineStartLoc = lineRange.location
                let oldIndent = prefix.leadingWhitespace

                // Determine new indent
                let newIndent: String
                if outdent {
                    if oldIndent.hasPrefix(indentUnit) {
                        newIndent = String(oldIndent.dropFirst(indentUnit.count))
                    } else if oldIndent.hasPrefix("\t") {
                        newIndent = String(oldIndent.dropFirst(1))
                    } else {
                        return true  // already at root, consume
                    }
                } else {
                    newIndent = oldIndent + indentUnit
                }

                // Build new marker. For numbered lists, recompute based on siblings
                // at the new indent level. For bullets/checkboxes, preserve marker.
                let newMarkerStr: String
                if case .numbered = prefix.marker {
                    let textStr = fullText as String
                    let allLines = textStr.components(separatedBy: "\n")
                    let prefixText = fullText.substring(to: lineStartLoc)
                    let currentLineIndex =
                        prefixText.isEmpty
                        ? 0
                        : prefixText.components(separatedBy: "\n").count - 1
                    let newNumber = computeNumberForIndent(
                        lines: allLines,
                        currentLineIndex: currentLineIndex,
                        targetIndent: newIndent
                    )
                    newMarkerStr = "\(newNumber). "
                } else {
                    newMarkerStr = markerString(for: prefix)
                }

                let newFullPrefix = newIndent + newMarkerStr
                let oldPrefixRange = NSRange(location: lineStartLoc, length: prefix.prefixLength)

                guard
                    textView.shouldChangeText(
                        in: oldPrefixRange, replacementString: newFullPrefix
                    )
                else { return true }
                textView.textStorage?.replaceCharacters(
                    in: oldPrefixRange, with: newFullPrefix
                )
                textView.didChangeText()

                let deltaLen = (newFullPrefix as NSString).length - prefix.prefixLength
                let newCursorLoc = max(lineStartLoc, selected.location + deltaLen)
                textView.selectedRange = NSRange(location: newCursorLoc, length: 0)
                return true
            }

            // Branch B: single-line selection — fall through to default Tab
            let selectedText = fullText.substring(with: selected)
            if !selectedText.contains("\n") {
                return false
            }

            // Branch C: multi-line selection — block indent/outdent
            let firstLineRange = fullText.lineRange(
                for: NSRange(location: selected.location, length: 0)
            )
            let lastCharLoc = selected.location + selected.length - 1
            let lastLineRange = fullText.lineRange(
                for: NSRange(location: lastCharLoc, length: 0)
            )
            let blockEnd = lastLineRange.location + lastLineRange.length
            let blockRange = NSRange(
                location: firstLineRange.location,
                length: blockEnd - firstLineRange.location
            )

            let blockText = fullText.substring(with: blockRange)
            let hasTrailingNewline = blockText.hasSuffix("\n")
            let bodyText = hasTrailingNewline ? String(blockText.dropLast()) : blockText
            let lines = bodyText.components(separatedBy: "\n")

            // Build context: lines before the block. Needed so numbered-list
            // renumbering accounts for external sibling chains.
            let textBeforeBlock = fullText.substring(to: firstLineRange.location)
            let contextLineCount =
                textBeforeBlock.isEmpty
                ? 0
                : textBeforeBlock.components(separatedBy: "\n").count - 1
            let fullTextStr = fullText as String
            let contextLines = Array(
                fullTextStr.components(separatedBy: "\n").prefix(contextLineCount)
            )

            let result = transformBlockIndent(
                lines: lines,
                contextLines: contextLines,
                outdent: outdent
            )
            let firstLineDelta = result.firstLineDelta
            let totalDelta = result.totalDelta

            var newBlockText = result.lines.joined(separator: "\n")
            if hasTrailingNewline { newBlockText += "\n" }

            guard textView.shouldChangeText(in: blockRange, replacementString: newBlockText)
            else { return true }
            textView.textStorage?.replaceCharacters(in: blockRange, with: newBlockText)
            textView.didChangeText()

            // Selection shifts with first line; length grows by deltas of lines 2..N
            let newSelStart = max(firstLineRange.location, selected.location + firstLineDelta)
            let newSelEnd = selected.location + selected.length + totalDelta
            let newSelLen = max(0, newSelEnd - newSelStart)
            textView.selectedRange = NSRange(location: newSelStart, length: newSelLen)
            return true
        }

        // MARK: Wrap selection (Cmd-B, Cmd-I)

        func wrapSelection(in textView: MarkdownTextView, with marker: String) {
            let fullText = textView.string as NSString
            let selected = textView.selectedRange
            let markerLen = (marker as NSString).length

            // Unwrap: selection is exactly bounded by markers on each side
            let outerStart = selected.location - markerLen
            let outerEnd = selected.location + selected.length
            if outerStart >= 0, outerEnd + markerLen <= fullText.length {
                let before = fullText.substring(
                    with: NSRange(location: outerStart, length: markerLen)
                )
                let after = fullText.substring(
                    with: NSRange(location: outerEnd, length: markerLen)
                )
                if before == marker && after == marker {
                    let totalRange = NSRange(
                        location: outerStart,
                        length: markerLen + selected.length + markerLen
                    )
                    let unwrapped =
                        selected.length > 0 ? fullText.substring(with: selected) : ""
                    guard textView.shouldChangeText(in: totalRange, replacementString: unwrapped)
                    else { return }
                    textView.textStorage?.replaceCharacters(in: totalRange, with: unwrapped)
                    textView.didChangeText()
                    textView.selectedRange = NSRange(
                        location: outerStart,
                        length: selected.length
                    )
                    return
                }
            }

            // Wrap
            if selected.length == 0 {
                let insert = marker + marker
                guard textView.shouldChangeText(in: selected, replacementString: insert)
                else { return }
                textView.textStorage?.replaceCharacters(in: selected, with: insert)
                textView.didChangeText()
                textView.selectedRange = NSRange(
                    location: selected.location + markerLen,
                    length: 0
                )
            } else {
                let content = fullText.substring(with: selected)
                let replacement = marker + content + marker
                guard textView.shouldChangeText(in: selected, replacementString: replacement)
                else { return }
                textView.textStorage?.replaceCharacters(in: selected, with: replacement)
                textView.didChangeText()
                textView.selectedRange = NSRange(
                    location: selected.location + markerLen,
                    length: selected.length
                )
            }
        }

        // MARK: Checkbox click-to-toggle

        func handleCheckboxClick(in textView: MarkdownTextView, at charIndex: Int) -> Bool {
            let fullText = textView.string as NSString
            guard charIndex >= 0, charIndex < fullText.length else { return false }
            let lineRange = fullText.lineRange(
                for: NSRange(location: charIndex, length: 0)
            )
            var line = fullText.substring(with: lineRange)
            if line.hasSuffix("\n") { line.removeLast() }
            if line.hasSuffix("\r") { line.removeLast() }

            guard let prefix = parseListPrefix(line),
                case .checkbox(let checked) = prefix.marker
            else { return false }

            // Bracket trio range: after leadingWhitespace + "- ", length 3 ("[x]" / "[ ]")
            let leadingLen = (prefix.leadingWhitespace as NSString).length
            let bracketStart = lineRange.location + leadingLen + 2
            let bracketRange = NSRange(location: bracketStart, length: 3)
            guard bracketRange.location + bracketRange.length <= fullText.length else {
                return false
            }
            guard NSLocationInRange(charIndex, bracketRange) else { return false }

            let replacement = checked ? "[ ]" : "[x]"
            guard textView.shouldChangeText(in: bracketRange, replacementString: replacement)
            else { return true }
            textView.textStorage?.replaceCharacters(in: bracketRange, with: replacement)
            textView.didChangeText()
            return true
        }

        // MARK: Styling

        func applyMarkdownStyling(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let text = textView.string
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            guard fullRange.length > 0 else { return }

            isApplyingStyling = true
            let selectedRanges = textView.selectedRanges

            let defaultFont = NSFont.systemFont(ofSize: parent.fontSize, weight: .regular)
            let defaultColor = EditorColors.text

            storage.beginEditing()

            // Reset all styling attributes (incl. paragraphStyle, so list indent doesn't bleed)
            storage.setAttributes(
                [
                    .font: defaultFont,
                    .foregroundColor: defaultColor,
                    .paragraphStyle: NSParagraphStyle.default,
                ],
                range: fullRange
            )

            // Process line by line
            let nsString = text as NSString
            nsString.enumerateSubstrings(in: fullRange, options: .byLines) {
                line, lineRange, _, _ in
                guard let line else { return }
                self.styleLine(line, range: lineRange, in: storage)
            }

            // Bold: **text** anywhere
            self.applyBoldStyling(in: storage, text: text, fullRange: fullRange)

            storage.endEditing()

            textView.selectedRanges = selectedRanges
            isApplyingStyling = false
        }

        private func styleLine(
            _ line: String,
            range lineRange: NSRange,
            in storage: NSTextStorage
        ) {
            // # Heading
            if line.hasPrefix("# ") {
                let headingFont = NSFont.systemFont(ofSize: parent.fontSize + 6, weight: .bold)
                storage.addAttribute(.font, value: headingFont, range: lineRange)
                if lineRange.length >= 2 {
                    let prefixRange = NSRange(location: lineRange.location, length: 2)
                    storage.addAttribute(
                        .foregroundColor, value: EditorColors.dimmed, range: prefixRange
                    )
                }
                return
            }
            // ## Subheading
            if line.hasPrefix("## ") {
                let subFont = NSFont.systemFont(ofSize: parent.fontSize + 3, weight: .semibold)
                storage.addAttribute(.font, value: subFont, range: lineRange)
                if lineRange.length >= 3 {
                    let prefixRange = NSRange(location: lineRange.location, length: 3)
                    storage.addAttribute(
                        .foregroundColor, value: EditorColors.dimmed, range: prefixRange
                    )
                }
                return
            }

            // List lines (bullets, numbered, checkboxes)
            guard let prefix = parseListPrefix(line) else { return }

            let defaultFont = NSFont.systemFont(ofSize: parent.fontSize, weight: .regular)
            let marker = markerString(for: prefix)
            let markerWidth =
                (marker as NSString).size(withAttributes: [.font: defaultFont]).width
            let leadingWidth: CGFloat =
                prefix.leadingWhitespace.isEmpty
                ? 0
                : (prefix.leadingWhitespace as NSString)
                    .size(withAttributes: [.font: defaultFont]).width

            // Hanging indent: wrapped lines align under content
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = 0
            style.headIndent = leadingWidth + markerWidth
            storage.addAttribute(.paragraphStyle, value: style, range: lineRange)

            // Dim the marker portion (after leading whitespace)
            let leadingLen = (prefix.leadingWhitespace as NSString).length
            let markerAbsStart = lineRange.location + leadingLen
            let markerLen = prefix.prefixLength - leadingLen
            let lineEnd = lineRange.location + lineRange.length
            if markerLen > 0, markerAbsStart + markerLen <= lineEnd {
                let markerRange = NSRange(location: markerAbsStart, length: markerLen)
                storage.addAttribute(
                    .foregroundColor, value: EditorColors.dimmed, range: markerRange
                )
            }

            // Checked checkbox: strikethrough + dim content
            if case .checkbox(let checked) = prefix.marker, checked {
                let contentStart = lineRange.location + prefix.prefixLength
                let contentLen = lineRange.length - prefix.prefixLength
                if contentLen > 0, contentStart + contentLen <= lineEnd {
                    let contentRange = NSRange(location: contentStart, length: contentLen)
                    storage.addAttribute(
                        .strikethroughStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: contentRange
                    )
                    storage.addAttribute(
                        .foregroundColor, value: EditorColors.dimmed, range: contentRange
                    )
                }
            }
        }

        private func applyBoldStyling(
            in storage: NSTextStorage,
            text: String,
            fullRange: NSRange
        ) {
            guard let regex = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*") else { return }
            let matches = regex.matches(in: text, range: fullRange)

            let boldFont = NSFont.systemFont(ofSize: parent.fontSize, weight: .bold)
            for match in matches {
                let contentRange = match.range(at: 1)
                storage.addAttribute(.font, value: boldFont, range: contentRange)

                let openRange = NSRange(location: match.range.location, length: 2)
                let closeEnd = match.range.location + match.range.length
                let closeRange = NSRange(location: closeEnd - 2, length: 2)
                storage.addAttribute(
                    .foregroundColor, value: EditorColors.dimmed, range: openRange
                )
                storage.addAttribute(
                    .foregroundColor, value: EditorColors.dimmed, range: closeRange
                )
            }
        }
    }
}

// MARK: - Editor Colors (matches SeminarlyColors as NSColor)

private enum EditorColors {
    static let text = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.91, green: 0.89, blue: 0.87, alpha: 1) // E8E4DD
            : NSColor(red: 0.17, green: 0.16, blue: 0.15, alpha: 1) // 2C2A26
    })

    static let dimmed = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.42, green: 0.40, blue: 0.36, alpha: 1) // 6B665C
            : NSColor(red: 0.62, green: 0.60, blue: 0.54, alpha: 1) // 9E9889
    })
}
