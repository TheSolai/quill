import SwiftUI
import AppKit

// MARK: - ToastCenter
//
// Lightweight in-app notification system. Views post toasts via
// `ToastCenter.shared.post(...)` and they show as small banners in the
// bottom-right of the window. Auto-dismiss after a configurable duration,
// or click to dismiss immediately.
//
// Used for transient notifications:
//   - Save success / failure
//   - Inbox refresh
//   - Backend connection lost/restored
//   - Action results
//
// For longer-lived state, prefer the editor's save indicator or the
// logs tab.

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var toasts: [Toast] = []
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    func post(_ toast: Toast) {
        // Replace any existing toast with the same id (so updates don't pile up)
        toasts.removeAll(where: { $0.id == toast.id })
        toasts.append(toast)
        // Auto-dismiss after the toast's duration
        let id = toast.id
        dismissTasks[id]?.cancel()
        dismissTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(toast.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }

    func postInfo(_ message: String, duration: TimeInterval = 3) {
        post(Toast(kind: .info, message: message, duration: duration))
    }

    func postSuccess(_ message: String, duration: TimeInterval = 3) {
        post(Toast(kind: .success, message: message, duration: duration))
    }

    func postWarning(_ message: String, duration: TimeInterval = 4) {
        post(Toast(kind: .warning, message: message, duration: duration))
    }

    func postError(_ message: String, duration: TimeInterval = 6) {
        post(Toast(kind: .error, message: message, duration: duration))
    }

    func dismiss(id: UUID) {
        toasts.removeAll(where: { $0.id == id })
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
    }

    func dismissAll() {
        toasts.removeAll()
        dismissTasks.values.forEach { $0.cancel() }
        dismissTasks.removeAll()
    }
}

// MARK: - Toast

struct Toast: Identifiable, Equatable {
    enum Kind {
        case info, success, warning, error

        var color: Color {
            switch self {
            case .info: return Color.blue
            case .success: return Color.green
            case .warning: return Color.orange
            case .error: return Color.red
            }
        }

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let message: String
    let duration: TimeInterval
    let timestamp: Date

    init(kind: Kind, message: String, duration: TimeInterval = 3) {
        self.id = UUID()
        self.kind = kind
        self.message = message
        self.duration = duration
        self.timestamp = Date()
    }
}

// MARK: - ToastBanner (overlay)

/// A floating banner view that shows all current toasts. Place this as
/// an .overlay(alignment: .bottomTrailing) on the root content view.
struct ToastBanner: View {
    @ObservedObject var center: ToastCenter
    let bg: Color
    let textPrimary: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(center.toasts) { toast in
                ToastRow(toast: toast, textPrimary: textPrimary, bg: bg) {
                    center.dismiss(id: toast.id)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .padding(12)
        .animation(.easeOut(duration: 0.2), value: center.toasts)
    }
}

struct ToastRow: View {
    let toast: Toast
    let textPrimary: Color
    let bg: Color
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.kind.icon)
                .font(.system(size: 12))
                .foregroundColor(toast.kind.color)
            Text(toast.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textPrimary)
                .lineLimit(3)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(bg.opacity(0.95))
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(toast.kind.color.opacity(0.3), lineWidth: 1)
        )
        .frame(maxWidth: 360)
        .onTapGesture(perform: onDismiss)
    }
}
