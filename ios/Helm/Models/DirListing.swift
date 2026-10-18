import Foundation

struct DirEntry: Identifiable, Hashable {
    var name: String
    var isDir: Bool
    var id: String { name }
}

struct DirListing {
    var path: String
    var entries: [DirEntry]

    init(json: JSONValue, requested: String) {
        path = json["path"]?.string ?? requested
        entries = (json["entries"]?.array ?? []).compactMap { e in
            if case .string(let n) = e { return DirEntry(name: n, isDir: true) }
            guard let n = e["name"]?.string else { return nil }
            return DirEntry(name: n, isDir: e["is_dir"]?.bool ?? true)
        }
        .filter { $0.isDir }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
