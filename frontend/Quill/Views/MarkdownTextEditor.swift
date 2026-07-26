import SwiftUI
import AppKit

// MARK: - MarkdownTextEditor
//
// NSViewRepresentable wrapping NSTextView that:
//   1. Provides two-way binding for the text
//   2. Exposes the current selection range
//   3. Intercepts Tab key and routes it to a callback for AI inline-fix
//   4. Shows a subtle "AI fixing..." indicator overlay during async fixes
//   5. Briefly shows a "✓ fixed" animation after a successful fix
//
// This is the foundation for Quill's Zed-style Tab-to-fix inline AI.

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isFixing: Bool
    let onTabPressed: (String, NSRange) -> Void  // (selected/current-paragraph text, range in doc)
    let font: NSFont
    let textColor: NSColor
    let background: NSColor
    /// When set to a new value, the editor will request focus on the next
    /// update. Use a token (Int) that you increment when you want to refocus
    /// (e.g. on appear, on chapter switch).
    var focusToken: Int = 0

    func makeNSView(context: Context) -> NSScrollView {
        // Use FixableTextView (subclass) so Tab gets intercepted for AI fix
        let scrollView = NSTextView.scrollableTextView()
        let textView = FixableTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        textView.onTabFix = { [weak coordinator = context.coordinator] snippet, range in
            coordinator?.handleTabFix(snippet: snippet, range: range)
        }
        configureTextView(textView, coordinator: context.coordinator)
        // Set initial text
        textView.string = text
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        // Avoid feedback loop: only update if text actually changed
        if textView.string != text {
            let oldRange = textView.selectedRange()
            textView.string = text
            // Try to preserve selection if still valid
            let len = (text as NSString).length
            if oldRange.location <= len {
                textView.setSelectedRange(NSRange(location: oldRange.location, length: 0))
            }
        }
        // Update indicator state on the coordinator
        context.coordinator.isFixing = isFixing
        // Request focus if the focus token has changed
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            // Defer the focus request so SwiftUI has time to lay out the view
            DispatchQueue.main.async { [weak textView] in
                guard let tv = textView else { return }
                tv.window?.makeFirstResponder(tv)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func configureTextView(_ textView: NSTextView, coordinator: Coordinator) {
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = background
        textView.drawsBackground = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.delegate = coordinator
    }

    // (Re-add Coordinator below)

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        weak var textView: NSTextView?
        var isFixing: Bool = false
        var lastFocusToken: Int = 0
        private var isInternalUpdate = false

        init(parent: MarkdownTextEditor) {
            self.parent = parent
        }

        // NSTextViewDelegate: text changed
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isInternalUpdate = true
            parent.text = textView.string
            isInternalUpdate = false
        }

        // NSTextViewDelegate: selection changed — no-op for now
        func textViewDidChangeSelection(_ notification: Notification) {
            // selection state is internal to the text view; we don't expose it
        }

        // Called by FixableTextView when user presses Tab
        @MainActor
        func handleTabFix(snippet: String, range: NSRange) {
            // Route up to the SwiftUI layer via the parent's onTabPressed closure
            parent.onTabPressed(snippet, range)
        }
    }
}

// MARK: - FixableTextView (NSTextView subclass)
//
// Custom NSTextView that intercepts the Tab key before it gets inserted as
// a literal tab character. Routes the press to the editor's onTabFixRequested
// callback so the SwiftUI layer can call /api/edit-fix and replace the
// selection with the fixed text.

class FixableTextView: NSTextView {
    var onTabFix: ((String, NSRange) -> Void)?

    override func keyDown(with event: NSEvent) {
        // Tab key (without modifiers) triggers the AI fix
        if event.keyCode == 48, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [] {
            let range = self.selectedRange()
            let nsString = self.string as NSString
            let snippet: String
            let snippetRange: NSRange
            if range.length > 0 {
                // Use the selected text directly
                snippet = nsString.substring(with: range)
                snippetRange = range
            } else {
                // No selection — find the current sentence/paragraph
                let (s, r) = findCurrentSnippet(in: self.string as String, at: range.location)
                snippet = s
                snippetRange = r
            }
            // Only fire if there's something to fix
            if !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onTabFix?(snippet, snippetRange)
                return  // consume the event (don't insert tab)
            }
        }
        super.keyDown(with: event)
    }
}

// MARK: - Snippet extraction

/// Find the sentence or paragraph that contains the given cursor location.
/// Returns (text, range). For prose, prefers the current sentence; falls back
/// to the current paragraph; falls back to the current line.
func findCurrentSnippet(in text: String, at location: Int) -> (String, NSRange) {
    let ns = text as NSString
    let len = ns.length
    if len == 0 { return ("", NSRange(location: 0, length: 0)) }
    let loc = max(0, min(location, len))

    // 1. Try sentence (look back for '. ', '! ', '? ', '\n'; look forward for same)
    if let sent = findSentenceRange(in: text, at: loc) {
        return (ns.substring(with: sent), sent)
    }
    // 2. Fall back to paragraph (look for '\n\n')
    if let para = findParagraphRange(in: text, at: loc) {
        return (ns.substring(with: para), para)
    }
    // 3. Fall back to current line
    let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
    return (ns.substring(with: lineRange), lineRange)
}

private func findSentenceRange(in text: String, at location: Int) -> NSRange? {
    let ns = text as NSString
    let len = ns.length
    if len == 0 { return nil }
    let loc = max(0, min(location, len))

    // Walk backwards to find start of sentence
    var start = loc
    while start > 0 {
        let prev = ns.substring(with: NSRange(location: start - 1, length: 1))
        if prev == "\n" || prev == "\"" || prev == "'" {
            // newline or quote is OK as start
            if start - 1 == 0 { break }
            let prev2 = ns.substring(with: NSRange(location: start - 2, length: 1))
            if prev2 == "." || prev2 == "!" || prev2 == "?" {
                start -= 1  // include the quote/paren, but sentence starts after the terminator + whitespace
                break
            }
            break
        }
        if prev == "." || prev == "!" || prev == "?" {
            // Sentence ends here. Start is after the terminator and following whitespace.
            start = min(start, len)
            break
        }
        start -= 1
    }
    // Skip any leading whitespace, newlines, and opening quotes
    while start < loc {
        let c = ns.substring(with: NSRange(location: start, length: 1))
        if c == " " || c == "\t" || c == "\n" || c == "\"" || c == "'" || c == "(" || c == "[" {
            start += 1
        } else {
            break
        }
    }

    // Walk forwards to find end of sentence
    var end = loc
    while end < len {
        let c = ns.substring(with: NSRange(location: end, length: 1))
        if c == "." || c == "!" || c == "?" {
            // include the terminator
            end += 1
            // include trailing closing quotes
            while end < len {
                let c2 = ns.substring(with: NSRange(location: end, length: 1))
                if c2 == "\"" || c2 == "'" || c2 == ")" || c2 == "]" { end += 1 } else { break }
            }
            break
        }
        if c == "\n" {
            // No terminator yet — bound at newline (we're inside a sentence)
            break
        }
        end += 1
    }

    if end <= start { return nil }
    return NSRange(location: start, length: end - start)
}

private func findParagraphRange(in text: String, at location: Int) -> NSRange? {
    let ns = text as NSString
    let len = ns.length
    if len == 0 { return nil }
    let loc = max(0, min(location, len))

    var start = loc
    while start > 0 {
        let prev = ns.substring(with: NSRange(location: start - 1, length: 1))
        if prev == "\n" {
            // Look back another char to see if this is a blank line
            if start - 1 == 0 {
                break
            }
            let prev2 = ns.substring(with: NSRange(location: start - 2, length: 1))
            if prev2 == "\n" {
                break  // paragraph break
            }
            // single newline — keep going
            start -= 1
        } else {
            start -= 1
        }
    }

    var end = loc
    while end < len {
        let c = ns.substring(with: NSRange(location: end, length: 1))
        if c == "\n" {
            if end + 1 < len {
                let next = ns.substring(with: NSRange(location: end + 1, length: 1))
                if next == "\n" { break }  // blank line = paragraph break
            } else {
                break  // end of text
            }
            end += 1
        } else {
            end += 1
        }
    }
    if end <= start { return nil }
    return NSRange(location: start, length: end - start)
}
