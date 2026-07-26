import SwiftUI
import AppKit

// MARK: - ChatInputView
//
// NSTextView wrapper for the AI assistant chat input. Behavior:
//   - Return (no modifiers) → triggers onSend
//   - Shift+Return → inserts a newline
//   - Cmd+A / Cmd+C / Cmd+V → standard text editing (default NSTextView)
//
// The default SwiftUI TextEditor doesn't let us distinguish Return from
// Shift+Return on macOS, so we wrap NSTextView directly.

struct ChatInputView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isDisabled: Bool
    let onSend: () -> Void
    let font: NSFont
    let textColor: NSColor
    let background: NSColor
    let border: NSColor
    let placeholderColor: NSColor
    /// When this changes, focus is requested.
    var focusToken: Int = 0

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = ChatInputTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 38))
        textView.minSize = NSSize(width: 0, height: 38)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 100)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: 100)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        textView.onSend = { [weak coordinator = context.coordinator] in
            coordinator?.handleSend()
        }
        configureTextView(textView, coordinator: context.coordinator)
        textView.string = text
        textView.delegate = context.coordinator
        context.coordinator.placeholder = placeholder
        context.coordinator.placeholderColor = placeholderColor
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = !isDisabled
        textView.alphaValue = isDisabled ? 0.5 : 1.0
        // Update placeholder if changed
        if context.coordinator.placeholder != placeholder {
            context.coordinator.placeholder = placeholder
            textView.needsDisplay = true
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
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
        textView.usesFindBar = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.delegate = coordinator
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputView
        weak var textView: NSTextView?
        var lastFocusToken: Int = 0
        var placeholder: String = ""
        var placeholderColor: NSColor = .secondaryLabelColor
        private var isInternalUpdate = false

        init(parent: ChatInputView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isInternalUpdate = true
            parent.text = textView.string
            isInternalUpdate = false
            textView.needsDisplay = true
        }

        @MainActor
        func handleSend() {
            parent.onSend()
        }
    }
}

// MARK: - ChatInputTextView (NSTextView subclass)
//
// Intercepts Return and Shift+Return:
//   - Return (no modifiers) → fires onSend
//   - Shift+Return → inserts a newline
// Cmd+A / Cmd+C / Cmd+V are passed through to super (default NSTextView).

class ChatInputTextView: NSTextView {
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Return key (keyCode 36) — send if no modifiers, insert newline if Shift held
        if event.keyCode == 36 {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.shift) {
                // Insert a literal newline
                super.insertText("\n", replacementRange: selectedRange())
                return
            }
            if mods.contains(.command) || mods.contains(.option) || mods.contains(.control) {
                // Let Cmd+Return / Option+Return etc. behave as usual
                super.keyDown(with: event)
                return
            }
            // Plain Return — send
            onSend?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Draw placeholder when empty
        guard let coordinator = (self.delegate as? ChatInputView.Coordinator) else { return }
        if self.string.isEmpty, !coordinator.placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: self.font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: coordinator.placeholderColor
            ]
            let inset = self.textContainerInset
            let point = NSPoint(x: inset.width + 2, y: inset.height)
            coordinator.placeholder.draw(at: point, withAttributes: attrs)
        }
    }
}