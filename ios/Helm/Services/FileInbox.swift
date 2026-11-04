import Foundation
import Observation

/// Files handed to Helm by another app ("Open in Helm" / share sheet), waiting to
/// be sent to the box. RootView shows the upload sheet while this is non-empty.
@Observable
final class FileInbox {
    static let shared = FileInbox()
    var pending: [PickedFile] = []

    /// Routes an incoming URL: certificates go to CertInbox, anything else is queued for upload.
    func receive(_ url: URL) {
        if ["p12", "pfx"].contains(url.pathExtension.lowercased()) {
            CertInbox.shared.receive(url)
            return
        }
        guard url.isFileURL, let f = PickedFile.load(url) else { return }
        pending.append(f)
        // iOS copies the document into Documents/Inbox; it's in memory now.
        try? FileManager.default.removeItem(at: url)
    }
}
