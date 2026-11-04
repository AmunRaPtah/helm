import Foundation
import Observation

/// Files handed to Helm by another app ("Open in Helm" / share sheet), waiting to
/// be sent to the box. RootView shows the upload sheet while this is non-empty.
@Observable
final class FileInbox {
    static let shared = FileInbox()
    /// Helm-owned temp copies; the upload deletes them once sent.
    var pending: [URL] = []

    /// Routes an incoming URL: certificates go to CertInbox, anything else is queued for upload.
    func receive(_ url: URL) {
        if ["p12", "pfx"].contains(url.pathExtension.lowercased()) {
            CertInbox.shared.receive(url)
            return
        }
        guard url.isFileURL, let copy = PhoneFiles.tempCopy(of: url) else { return }
        pending.append(copy)
        // iOS copies shared documents into Documents/Inbox; drop that copy. Anything
        // else (opened in place from Files, or Helm's own folder) is left alone.
        if url.standardizedFileURL.path.hasPrefix(PhoneFiles.systemInbox.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
