import Foundation
import Observation
import UIKit

/// The Drop thread: files and notes between this phone and the box, like a chat
/// with yourself. Box files live in /root/drop; on the phone, everything sent or
/// downloaded through Drop is kept in Files > On My iPhone > Helm > Drop.
@MainActor @Observable
final class DropStore {
    static let shared = DropStore()

    /// A send that hasn't landed yet (or failed and can be retried).
    final class Pending: Identifiable {
        let id = UUID()
        let file: URL?
        let text: String
        let size: Int64
        var sent: Int64 = 0
        var error: String?
        init(file: URL?, text: String, size: Int64) { self.file = file; self.text = text; self.size = size }
        var name: String { file?.lastPathComponent ?? "" }
    }

    private(set) var items: [DropItem] = []
    private(set) var pending: [Pending] = []
    private(set) var boxDir = "/root/drop"
    private(set) var loaded = false
    var error: String?
    /// Item id -> download in flight; failures keep their message until retried.
    private(set) var downloading: Set<Int> = []
    private(set) var downloadErrors: [Int: String] = [:]
    /// True while the Drop screen is on screen: polls faster and marks new items read.
    var isVisible = false {
        didSet { if isVisible { markRead() } }
    }

    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private var local: [String: String]
    private(set) var seenId: Int

    private static let autoDownloadLimit: Int64 = 25 * 1024 * 1024

    private init() {
        seenId = UserDefaults.standard.integer(forKey: "helm.drop.seen")
        local = UserDefaults.standard.dictionary(forKey: "helm.drop.local") as? [String: String] ?? [:]
        try? FileManager.default.createDirectory(at: Self.phoneDir, withIntermediateDirectories: true)
    }

    static var phoneDir: URL { PhoneFiles.root.appendingPathComponent("Drop", isDirectory: true) }

    var unread: Int { items.filter { $0.sender == .box && $0.id > seenId }.count }

    // MARK: Sync

    /// Polls while the app is active: every 3s with Drop open, every 20s otherwise (for the badge).
    func run(api: APIClient) async {
        self.api = api
        while !Task.isCancelled {
            await refresh()
            let wait: UInt64 = isVisible ? 3 : 20
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
        }
    }

    func refresh() async {
        guard let api else { return }
        do {
            let page = try await api.dropList()
            boxDir = page.dir
            let before = Set(items.map(\.id))
            let wasLoaded = loaded
            items = page.items
            loaded = true
            error = nil
            if isVisible {
                markRead()
                // Only things that arrived while watching, not the whole history on launch.
                if wasLoaded { for it in items where !before.contains(it.id) { autoDownload(it) } }
            }
        } catch {
            if !(error is CancellationError) { self.error = APIClient.describe(error) }
        }
    }

    func markRead() {
        guard let last = items.last?.id, last > seenId else { return }
        seenId = last
        UserDefaults.standard.set(last, forKey: "helm.drop.seen")
    }

    // MARK: Sending

    /// owned: the URLs are Helm temp copies (photos, share sheet); they are kept in the
    /// phone's Drop folder after sending. Others are copied first so the picker's
    /// security scope doesn't have to outlive the upload.
    func send(_ urls: [URL], owned: Bool, caption: String = "") {
        Task {
            for (n, url) in urls.enumerated() {
                let copy: URL? = owned ? url : await Task.detached { PhoneFiles.tempCopy(of: url) }.value
                guard let file = copy else {
                    error = "Couldn't read \(url.lastPathComponent)"
                    continue
                }
                let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                let p = Pending(file: file, text: n == urls.count - 1 ? caption : "", size: size)
                pending.append(p)
                Task { await upload(p) }
            }
        }
    }

    func sendNote(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let p = Pending(file: nil, text: t, size: 0)
        pending.append(p)
        Task { await upload(p) }
    }

    func retry(_ p: Pending) {
        p.error = nil
        p.sent = 0
        bump()
        Task { await upload(p) }
    }

    func discard(_ p: Pending) {
        pending.removeAll { $0.id == p.id }
        if let f = p.file { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
    }

    private func upload(_ p: Pending) async {
        guard let api else { p.error = "Not connected"; bump(); return }
        let bg = BackgroundTime()
        defer { bg.end() }
        do {
            let item: DropItem
            if let file = p.file {
                try await Task.detached { try LocalTree.materialize(file) }.value
                item = try await api.dropUpload(file: file, filename: file.lastPathComponent, caption: p.text) { [weak self] n in
                    Task { @MainActor in p.sent = n; self?.bump() }
                }
                keep(file, for: item)
            } else {
                item = try await api.dropNote(p.text)
            }
            pending.removeAll { $0.id == p.id }
            if !items.contains(where: { $0.id == item.id }) { items.append(item) }
            markRead()
            Haptics.tap()
        } catch {
            p.error = APIClient.describe(error)
            bump()
        }
    }

    /// Pending is a plain class; reassigning the array tells observers it changed.
    private func bump() { pending = pending }

    // MARK: Local copies

    func localURL(_ item: DropItem) -> URL? {
        guard let name = local[String(item.id)] else { return nil }
        let u = Self.phoneDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private func keep(_ file: URL, for item: DropItem) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.phoneDir, withIntermediateDirectories: true)
        let dest = PhoneFiles.unique(Self.phoneDir.appendingPathComponent(item.localName))
        do {
            try fm.moveItem(at: file, to: dest)
            try? fm.removeItem(at: file.deletingLastPathComponent())
            remember(dest, for: item)
        } catch {
            try? fm.removeItem(at: file.deletingLastPathComponent())
        }
    }

    private func remember(_ url: URL, for item: DropItem) {
        local[String(item.id)] = url.lastPathComponent
        UserDefaults.standard.set(local, forKey: "helm.drop.local")
    }

    private func autoDownload(_ item: DropItem) {
        guard item.kind == .file, item.sender == .box, item.exists, !item.isDir,
              item.size <= Self.autoDownloadLimit, localURL(item) == nil else { return }
        download(item)
    }

    func download(_ item: DropItem, then open: ((URL) -> Void)? = nil) {
        guard let path = item.path, let api, !downloading.contains(item.id) else { return }
        downloading.insert(item.id)
        downloadErrors[item.id] = nil
        Task {
            let bg = BackgroundTime()
            defer { bg.end(); downloading.remove(item.id) }
            do {
                let tmp = try await api.fsDownload(path)
                let fm = FileManager.default
                try fm.createDirectory(at: Self.phoneDir, withIntermediateDirectories: true)
                let dest = PhoneFiles.unique(Self.phoneDir.appendingPathComponent(item.localName))
                try fm.moveItem(at: tmp, to: dest)
                remember(dest, for: item)
                open?(dest)
            } catch {
                if !(error is CancellationError) { downloadErrors[item.id] = APIClient.describe(error) }
            }
        }
    }

    func delete(_ item: DropItem, everywhere: Bool) async {
        guard let api else { return }
        do {
            try await api.dropDelete(item.id, deleteFile: everywhere)
            items.removeAll { $0.id == item.id }
            if everywhere, let u = localURL(item) { try? FileManager.default.removeItem(at: u) }
            local[String(item.id)] = nil
            UserDefaults.standard.set(local, forKey: "helm.drop.local")
        } catch {
            self.error = APIClient.describe(error)
        }
    }
}
