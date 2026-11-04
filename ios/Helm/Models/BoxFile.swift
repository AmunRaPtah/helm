import Foundation

/// One entry in a box directory (GET /box/fs/list).
struct FsEntry: Identifiable, Hashable {
    var name: String
    var path: String
    var isDir: Bool
    var size: Int64
    var mtime: Date
    var isLink: Bool
    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

struct FsListing {
    var path: String
    var parent: String?
    var entries: [FsEntry]

    init(json: JSONValue) {
        path = json["path"]?.string ?? "/"
        parent = json["parent"]?.string
        let base = path
        entries = (json["entries"]?.array ?? []).compactMap { e in
            guard let n = e["name"]?.string else { return nil }
            return FsEntry(name: n, path: FsPath.join(base, n), isDir: e["is_dir"]?.bool ?? false,
                           size: Int64(e["size"]?.double ?? 0),
                           mtime: Date(timeIntervalSince1970: e["mtime"]?.double ?? 0),
                           isLink: e["is_link"]?.bool ?? false)
        }
    }
}

/// Every file under a box folder, relative to it (GET /box/fs/tree).
struct FsTree {
    struct File { var rel: String; var size: Int64 }
    var root: String
    var name: String
    var files: [File]
    var dirs: [String]
    var totalSize: Int64

    init(json: JSONValue) {
        root = json["root"]?.string ?? ""
        name = json["name"]?.string ?? (root as NSString).lastPathComponent
        files = (json["files"]?.array ?? []).compactMap { f in
            guard let r = f["rel"]?.string else { return nil }
            return File(rel: r, size: Int64(f["size"]?.double ?? 0))
        }
        dirs = json["dirs"]?.stringArray ?? []
        totalSize = Int64(json["total_size"]?.double ?? 0)
    }
}

enum FsPath {
    static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    static func parent(_ p: String) -> String {
        let parent = (p as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
