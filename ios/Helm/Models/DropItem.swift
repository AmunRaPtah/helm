import Foundation

/// One bubble in the Drop thread: a file or a text note, sent by the phone or the box.
struct DropItem: Identifiable, Hashable {
    enum Sender: String { case phone, box }
    enum Kind: String { case file, note }

    var id: Int
    var date: Date
    var sender: Sender
    var kind: Kind
    var name: String
    var path: String?
    var size: Int64
    var text: String
    var exists: Bool
    var isDir: Bool

    init?(json v: JSONValue) {
        guard let id = v["id"]?.int else { return nil }
        self.id = id
        date = Date(timeIntervalSince1970: v["ts"]?.double ?? 0)
        sender = Sender(rawValue: v["from"]?.string ?? "") ?? .box
        kind = Kind(rawValue: v["kind"]?.string ?? "") ?? .note
        name = v["name"]?.string ?? ""
        path = v["path"]?.string
        size = Int64(v["size"]?.double ?? 0)
        text = v["text"]?.string ?? ""
        exists = v["exists"]?.bool ?? true
        isDir = v["is_dir"]?.bool ?? false
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    /// What lands on the phone: folders come down as a .zip.
    var localName: String { isDir ? name + ".zip" : name }
}

struct DropPage {
    var dir: String
    var lastId: Int
    var items: [DropItem]

    init(json v: JSONValue) {
        dir = v["dir"]?.string ?? "/root/drop"
        lastId = v["last_id"]?.int ?? 0
        items = (v["items"]?.array ?? []).compactMap(DropItem.init(json:))
    }
}
