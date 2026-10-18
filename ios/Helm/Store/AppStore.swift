import Foundation
import Observation

@Observable
@MainActor
final class AppStore {
    var config: ServerConfig
    private(set) var sessions: [Session]
    private(set) var harnesses: [Harness]
    private(set) var listError: String?
    private(set) var lastSync: Date?
    private(set) var isRefreshing = false

    @ObservationIgnored private var chats: [String: ChatModel] = [:]

    init() {
        config = ServerConfig.load()
        sessions = DiskCache.loadSessions()
        harnesses = DiskCache.loadHarnesses()
    }

    var api: APIClient { APIClient(config: config) }

    func updateConfig(_ c: ServerConfig) {
        let changed = c.normalizedURLString != config.normalizedURLString
        c.save()
        config = ServerConfig.load()
        for chat in chats.values { chat.updateConfig(config) }
        if changed {
            chats.values.forEach { $0.stop() }
            chats.removeAll()
            sessions = []
            DiskCache.clearAll()
        }
    }

    // MARK: Sessions

    func refresh() async {
        guard config.isConfigured, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let list = try await api.sessions()
            sessions = list
            listError = nil
            lastSync = Date()
            DiskCache.saveSessions(list)
            for s in list { chats[s.id]?.mergeSession(s) }
        } catch is CancellationError {
        } catch {
            listError = APIClient.describe(error)
        }
    }

    func refreshHarnesses() async {
        guard config.isConfigured else { return }
        if let h = try? await api.harnesses(), !h.isEmpty {
            harnesses = h
            DiskCache.saveHarnesses(h)
        }
    }

    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    func upsert(_ s: Session) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.insert(s, at: 0) }
        sessions.sort { $0.updated > $1.updated }
        DiskCache.saveSessions(sessions)
    }

    func create(_ n: APIClient.NewSession) async throws -> Session {
        let s = try await api.createSession(n)
        upsert(s)
        if let cwd = n.cwd { Recents.add(cwd) }
        return s
    }

    func delete(_ id: String) async {
        let backup = sessions
        sessions.removeAll { $0.id == id }
        do {
            try await api.delete(id)
            chats[id]?.stop()
            chats[id] = nil
            DiskCache.deleteEvents(id)
            DiskCache.saveSessions(sessions)
        } catch {
            sessions = backup
            listError = APIClient.describe(error)
        }
    }

    func rename(_ id: String, to title: String) async throws {
        let s = try await api.rename(id, title: title)
        upsert(s)
        chats[id]?.mergeSession(s)
    }

    func chat(for session: Session) -> ChatModel {
        if let c = chats[session.id] { return c }
        let c = ChatModel(session: session, store: self)
        chats[session.id] = c
        return c
    }
}

/// Recently used working directories for the cwd picker.
enum Recents {
    private static let key = "helm.recentDirs"
    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func add(_ path: String) {
        var list = all.filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: key)
    }
}
