import Foundation

// MARK: - InboxMessage
//
// Lightweight email message struct. Stored in AppState so the Inbox tab
// can observe the published list and render immediately. Backend fetches
// happen in AppState (so the data is always available), and the Inbox tab
// just reads from the published property.

struct InboxMessage: Identifiable, Hashable {
    let id: String
    let from: String
    let subject: String
    let preview: String
    let body: String
    let timestamp: String
    let labels: [String]

    static func from(json: [String: Any]) -> InboxMessage? {
        guard let id = json["id"] as? String else { return nil }
        let from = json["from"] as? String ?? "unknown"
        let subject = json["subject"] as? String ?? "(no subject)"
        let preview = json["preview"] as? String ?? json["text"] as? String ?? ""
        let body = json["body"] as? String ?? json["text"] as? String ?? preview
        let timestamp = json["created_at"] as? String ?? json["timestamp"] as? String ?? ""
        let labels = (json["labels"] as? [String]) ?? []
        return InboxMessage(
            id: id, from: from, subject: subject, preview: preview,
            body: body, timestamp: timestamp, labels: labels
        )
    }
}
