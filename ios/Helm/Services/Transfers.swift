import Foundation
import Observation
import UIKit

/// One upload or download, file or whole folder. Folders move file by file so the
/// tree is rebuilt on the other side and one bad file doesn't sink the rest.
@MainActor @Observable
final class Transfer: Identifiable {
    enum Kind { case upload, download }
    enum State: Equatable { case running, done, failed(String), cancelled }

    let id = UUID()
    let kind: Kind
    let name: String
    let isFolder: Bool
    var state: State = .running
    var totalBytes: Int64 = 0
    var doneBytes: Int64 = 0
    var totalFiles = 0
    var doneFiles = 0
    var current = ""
    var failures: [String] = []
    /// Box path an upload landed at, or the box path a download came from.
    var remotePath: String?
    /// Where a download was saved on the phone.
    var localURL: URL?
    var task: Task<Void, Never>?

    init(kind: Kind, name: String, isFolder: Bool) {
        self.kind = kind
        self.name = name
        self.isFolder = isFolder
    }

    var isRunning: Bool { state == .running }
    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(doneBytes) / Double(totalBytes))
    }
}

@MainActor @Observable
final class Transfers {
    static let shared = Transfers()
    var items: [Transfer] = []
    /// Bumped whenever an upload finishes, so open box listings can refresh.
    var uploadsFinished = 0

    var activeCount: Int { items.filter(\.isRunning).count }

    /// Uploads local files and folders into a box directory, one transfer per item.
    /// ownedTemp: the URLs are Helm's own temp copies, deleted once sent.
    func upload(_ urls: [URL], to dir: String, api: APIClient, ownedTemp: Bool = false) {
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
            let t = Transfer(kind: .upload, name: url.lastPathComponent, isFolder: isDir)
            items.insert(t, at: 0)
            t.task = Task { await runUpload(t, url: url, dir: dir, api: api, ownedTemp: ownedTemp) }
        }
    }

    /// Downloads a box file or folder into the app's Documents (Files > On My iPhone > Helm).
    /// asZip fetches a folder as one .zip instead of rebuilding the tree.
    func download(_ entry: FsEntry, api: APIClient, asZip: Bool = false) {
        let t = Transfer(kind: .download, name: entry.name + (asZip ? ".zip" : ""), isFolder: entry.isDir && !asZip)
        t.remotePath = entry.path
        if !entry.isDir { t.totalBytes = entry.size; t.totalFiles = 1 }
        items.insert(t, at: 0)
        t.task = Task { await runDownload(t, entry: entry, api: api, asZip: asZip) }
    }

    func cancel(_ t: Transfer) { t.task?.cancel() }

    func clearFinished() { items.removeAll { !$0.isRunning } }

    // MARK: Upload

    private func runUpload(_ t: Transfer, url: URL, dir: String, api: APIClient, ownedTemp: Bool) async {
        let scoped = url.startAccessingSecurityScopedResource()
        let bg = BackgroundTime()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            if ownedTemp { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            bg.end()
            uploadsFinished += 1
        }
        do {
            if t.isFolder {
                t.current = "Scanning\u{2026}"
                let plan = try await Task.detached { try LocalTree.scan(url) }.value
                t.totalFiles = plan.files.count
                t.totalBytes = plan.totalSize
                let root = try await api.fsMkdir(FsPath.join(dir, url.lastPathComponent), unique: true)
                t.remotePath = root
                for d in plan.emptyDirs { _ = try await api.fsMkdir(FsPath.join(root, d)) }
                for f in plan.files {
                    try Task.checkCancellation()
                    do {
                        try await sendOne(t, file: f.url, rel: f.rel, size: f.size, dir: root, api: api)
                    } catch let e where !(e is CancellationError) {
                        t.failures.append("\(f.rel): \(APIClient.describe(e))")
                    }
                }
            } else {
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                t.totalFiles = 1
                t.totalBytes = size
                t.remotePath = try await sendOne(t, file: url, rel: nil, size: size, dir: dir, api: api)
            }
            finish(t)
        } catch {
            fail(t, error)
        }
    }

    @discardableResult
    private func sendOne(_ t: Transfer, file: URL, rel: String?, size: Int64, dir: String, api: APIClient) async throws -> String {
        t.current = rel ?? file.lastPathComponent
        let base = t.doneBytes
        let index = t.doneFiles
        // Pulls iCloud Drive files that are only placeholders down to the phone first.
        try await Task.detached { try LocalTree.materialize(file) }.value
        let path = try await api.fsUpload(file: file, filename: file.lastPathComponent, dir: dir, rel: rel) { sent in
            Task { @MainActor in
                if t.doneFiles == index { t.doneBytes = base + (size > 0 ? min(sent, size) : sent) }
            }
        }
        t.doneFiles += 1
        t.doneBytes = base + size
        return path
    }

    // MARK: Download

    private func runDownload(_ t: Transfer, entry: FsEntry, api: APIClient, asZip: Bool) async {
        let bg = BackgroundTime()
        defer { bg.end() }
        let fm = FileManager.default
        do {
            if entry.isDir && !asZip {
                t.current = "Listing\u{2026}"
                let tree = try await api.fsTree(entry.path)
                t.totalFiles = tree.files.count
                t.totalBytes = tree.totalSize
                let root = PhoneFiles.unique(PhoneFiles.root.appendingPathComponent(entry.name, isDirectory: true))
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                t.localURL = root
                for d in tree.dirs {
                    try fm.createDirectory(at: root.appendingPathComponent(d, isDirectory: true),
                                           withIntermediateDirectories: true)
                }
                for f in tree.files {
                    try Task.checkCancellation()
                    t.current = f.rel
                    do {
                        let tmp = try await api.fsDownload(FsPath.join(tree.root, f.rel))
                        let dest = root.appendingPathComponent(f.rel)
                        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? fm.removeItem(at: dest)
                        try fm.moveItem(at: tmp, to: dest)
                    } catch let e where !(e is CancellationError) {
                        t.failures.append("\(f.rel): \(APIClient.describe(e))")
                    }
                    t.doneFiles += 1
                    t.doneBytes += f.size
                }
            } else {
                t.current = t.name
                let tmp = try await api.fsDownload(entry.path)
                let dest = PhoneFiles.unique(PhoneFiles.root.appendingPathComponent(t.name))
                try fm.moveItem(at: tmp, to: dest)
                t.localURL = dest
                t.doneFiles = 1
                let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                t.totalBytes = max(t.totalBytes, size)
                t.doneBytes = t.totalBytes
            }
            finish(t)
        } catch {
            fail(t, error)
        }
    }

    // MARK: Helpers

    private func finish(_ t: Transfer) {
        t.current = ""
        if t.failures.isEmpty {
            t.state = .done
            Haptics.success()
        } else {
            t.state = .failed("\(t.failures.count) of \(t.totalFiles) files failed")
            Haptics.warning()
        }
    }

    private func fail(_ t: Transfer, _ error: Error) {
        t.current = ""
        if error is CancellationError || Task.isCancelled {
            t.state = .cancelled
        } else {
            t.state = .failed(APIClient.describe(error))
            Haptics.warning()
        }
    }
}

/// Asks iOS for extra time so a transfer survives a short trip out of the app.
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "helm-transfer") { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Walks a folder picked on the phone into the list of files to send.
enum LocalTree {
    struct File { var url: URL; var rel: String; var size: Int64 }
    struct Plan { var files: [File] = []; var emptyDirs: [String] = []; var totalSize: Int64 = 0 }

    static func scan(_ root: URL) throws -> Plan {
        var plan = Plan()
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let rootPath = root.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw APIError.transport("Couldn't read folder \(root.lastPathComponent)")
        }
        var dirsWithChildren = Set<String>()
        var allDirs: [String] = []
        for case let url as URL in walker {
            var u = url.standardizedFileURL
            var name = u.lastPathComponent
            if name == ".DS_Store" { continue }
            // iCloud placeholder ".Report.pdf.icloud" stands for "Report.pdf".
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
                u = u.deletingLastPathComponent().appendingPathComponent(name)
            }
            let rel = String(u.path.dropFirst(rootPath.count + 1))
            guard !rel.isEmpty else { continue }
            let parent = (rel as NSString).deletingLastPathComponent
            if !parent.isEmpty { dirsWithChildren.insert(parent) }
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                allDirs.append(rel)
            } else {
                let size = Int64(v?.fileSize ?? 0)
                plan.files.append(File(url: u, rel: rel, size: size))
                plan.totalSize += size
            }
        }
        plan.emptyDirs = allDirs.filter { !dirsWithChildren.contains($0) }
        return plan
    }

    /// Coordinated read: downloads an iCloud placeholder, a no-op for local files.
    static func materialize(_ url: URL) throws {
        var coordError: NSError?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            if !FileManager.default.isReadableFile(atPath: u.path) {
                readError = APIError.transport("Can't read \(url.lastPathComponent)")
            }
        }
        if let e = coordError ?? readError { throw e }
    }
}

/// Helm's on-phone storage: the app's Documents folder, which the Files app shows
/// under On My iPhone > Helm.
enum PhoneFiles {
    static var root: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Directory where iOS drops "Open in Helm" copies; hidden from the browser.
    static var systemInbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            let cand = dir.appendingPathComponent(name, isDirectory: url.hasDirectoryPath)
            if !fm.fileExists(atPath: cand.path) { return cand }
            n += 1
        }
    }

    /// Copies a file into a fresh temp dir Helm owns (the dir is removed after upload).
    static func tempCopy(of url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID().uuidString)", isDirectory: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        var ok = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { u in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: u, to: dest)
                ok = true
            } catch {}
        }
        return ok ? dest : nil
    }
}
