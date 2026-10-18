import Foundation

struct Harness: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var command: String
    var supportsProfiles: Bool
    var profiles: [String]
    var available: Bool
    var models: [String]
    var defaultModel: String?
    var note: String?

    init?(json: JSONValue) {
        guard let id = json["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"]?.string ?? id
        command = json["command"]?.string ?? id
        supportsProfiles = json["supports_profiles"]?.bool ?? false
        profiles = json["profiles"]?.stringArray ?? []
        available = json["available"]?.bool ?? true
        models = json["models"]?.stringArray ?? []
        defaultModel = json["default_model"]?.string
        note = json["note"]?.string
    }

    init(from decoder: Decoder) throws {
        let v = try JSONValue(from: decoder)
        guard let h = Harness(json: v) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "harness without id"))
        }
        self = h
    }

    enum CodingKeys: String, CodingKey {
        case id, name, command, profiles, available, models, note
        case supportsProfiles = "supports_profiles"
        case defaultModel = "default_model"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(command, forKey: .command)
        try c.encode(supportsProfiles, forKey: .supportsProfiles)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(available, forKey: .available)
        try c.encode(models, forKey: .models)
        try c.encodeIfPresent(defaultModel, forKey: .defaultModel)
        try c.encodeIfPresent(note, forKey: .note)
    }
}
