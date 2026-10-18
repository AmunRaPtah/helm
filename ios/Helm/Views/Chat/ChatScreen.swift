import SwiftUI

/// Resolves a session id to a ChatModel, fetching the session if it isn't cached.
struct ChatScreen: View {
    let sessionId: String
    @Environment(AppStore.self) private var store
    @State private var error: String?

    var body: some View {
        if let s = store.session(sessionId) {
            ChatView(model: store.chat(for: s))
        } else {
            Group {
                if let error {
                    ContentUnavailableView("Couldn't open chat", systemImage: "exclamationmark.bubble", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .task {
                do { store.upsert(try await store.api.session(sessionId)) }
                catch { self.error = APIClient.describe(error) }
            }
        }
    }
}
