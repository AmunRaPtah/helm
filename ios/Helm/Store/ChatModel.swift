import Foundation
import Observation

struct PendingMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var attachments: [String]
    var failed = false
}

struct Attachment: Identifiable, Equatable {
    let id = UUID()
    var filename: String
    var path: String?
    var error: String?
    var isUploading: Bool { path == nil && error == nil }
}

/// State for one open chat: transcript, live stream, composer.
@Observable
@MainActor
final class ChatModel {
    private(set) var session: Session
    private(set) var transcript = Transcript()
    private(set) var pending: [PendingMessage] = []
    var draft = ""
    var attachments: [Attachment] = []
    var banner: String?
    private(set) var isResuming = false
    /// Bumped when the turn finishes live, so the view can play a haptic.
    private(set) var turnCompletions = 0

    let stream: SessionStream

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var rawEvents: [HelmEvent] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var openedAt = Date().timeIntervalSince1970

    init(session: Session, store: AppStore) {
        self.session = session
        self.store = store
        self.stream = SessionStream(sessionId: session.id, config: store.config)
        if let log = DiskCache.loadEvents(session.id) {
            rawEvents = log.events
            for e in log.events { transcript.apply(e) }
        }
        stream.onEvents = { [weak self] batch in self?.ingest(batch) }
    }

    var api: APIClient { APIClient(config: stream.config) }

    var state: SessionState {
        // The latest status event is fresher than the polled session object,
        // unless the session was updated after it.
        if let s = transcript.lastState, (transcript.stateChangedAt ?? 0) >= session.updated - 1 { return s }
        return session.state
    }

    var isRunning: Bool { state == .running || state == .starting }
    var isExited: Bool { state == .exited }
    var canSend: Bool {
        !isRunning && !isExited && !attachments.contains { $0.isUploading }
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.contains { $0.path != nil })
    }

    // MARK: Lifecycle

    func start() {
        openedAt = Date().timeIntervalSince1970
        stream.start(after: transcript.maxSeq)
    }

    func stop() {
        stream.stop()
        persistNow()
    }

    func updateConfig(_ c: ServerConfig) {
        stream.config = c
        if stream.isRunning { stream.reconnectNow() }
    }

    func mergeSession(_ s: Session) {
        let wasExited = session.state == .exited
        session = s
        if wasExited, s.state != .exited, stream.isRunning { stream.reconnectNow() }
    }

    func refreshSession() async {
        if let s = try? await api.session(session.id) {
            session = s
            store?.upsert(s)
        }
    }

    // MARK: Events

    private func ingest(_ batch: [HelmEvent]) {
        var changed = false
        for e in batch {
            let wasRunning = isRunning
            if transcript.apply(e) { changed = true }
            rawEvents.append(e)
            if e.type == "user" { reconcilePending(e.text) }
            if e.type == "status", wasRunning, !isRunning, (e.ts ?? 0) >= openedAt - 2 {
                turnCompletions += 1
            }
        }
        if let last = batch.last?.ts, last > session.updated {
            session.updated = last
            session.lastSeq = max(session.lastSeq, transcript.maxSeq)
        }
        if changed { schedulePersist() }
    }

    private func reconcilePending(_ text: String) {
        guard !pending.isEmpty else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = pending.firstIndex(where: { t.hasPrefix($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            pending.remove(at: i)
        } else {
            pending.removeFirst()
        }
    }

    // MARK: Actions

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = attachments.compactMap(\.path)
        guard canSend else { return }
        draft = ""
        attachments = []
        let msg = PendingMessage(text: text, attachments: paths)
        pending.append(msg)
        Haptics.send()
        do {
            try await api.send(session.id, text: text, attachments: paths)
            banner = nil
            if !stream.isRunning { start() }
        } catch {
            if let i = pending.firstIndex(where: { $0.id == msg.id }) { pending[i].failed = true }
            banner = APIClient.describe(error)
            Haptics.warning()
        }
    }

    func retry(_ p: PendingMessage) async {
        pending.removeAll { $0.id == p.id }
        draft = p.text
        attachments = p.attachments.map { Attachment(filename: ($0 as NSString).lastPathComponent, path: $0) }
        await send()
    }

    func discard(_ p: PendingMessage) { pending.removeAll { $0.id == p.id } }

    func interrupt() async {
        Haptics.tap()
        if await stream.sendFrame(.object(["type": .string("interrupt")])) { return }
        do { try await api.interrupt(session.id) } catch { banner = APIClient.describe(error) }
    }

    func resume() async {
        isResuming = true
        defer { isResuming = false }
        do {
            let s = try await api.resume(session.id)
            session = s
            store?.upsert(s)
            banner = nil
            stream.reconnectNow()
        } catch {
            banner = APIClient.describe(error)
        }
    }

    func upload(data: Data, filename: String, mimeType: String) async {
        let a = Attachment(filename: filename)
        attachments.append(a)
        do {
            let path = try await api.upload(sessionId: session.id, data: data, filename: filename, mimeType: mimeType)
            if let i = attachments.firstIndex(where: { $0.id == a.id }) { attachments[i].path = path }
        } catch {
            if let i = attachments.firstIndex(where: { $0.id == a.id }) { attachments[i].error = APIClient.describe(error) }
        }
    }

    func removeAttachment(_ a: Attachment) { attachments.removeAll { $0.id == a.id } }

    // MARK: Persistence

    private func schedulePersist() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.persistNow()
        }
    }

    func persistNow() {
        saveTask?.cancel()
        saveTask = nil
        // Drop deltas that a final `assistant` already superseded.
        let finals = Set(rawEvents.filter { $0.type == "assistant" }.compactMap(\.msgId))
        rawEvents.removeAll { ev in
            guard ev.type == "assistant_delta", let id = ev.msgId else { return false }
            return finals.contains(id)
        }
        DiskCache.saveEvents(session.id, .init(lastSeq: transcript.maxSeq, events: rawEvents))
    }
}
