import SwiftUI

// MARK: - Chat Message

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String
    var actions: [SuggestedAction] = []

    enum Role {
        case user, assistant
    }
}

// MARK: - Chat Service

@Observable
final class ChatService {
    var messages: [ChatMessage] = []
    var isLoading = false

    var isConfigured: Bool {
        !AppGroupManager.readServerHost().isEmpty
    }

    func sendMessage(_ text: String, store: LutronStore) async {
        let userMessage = ChatMessage(role: .user, content: text)
        await MainActor.run { messages.append(userMessage) }
        await MainActor.run { isLoading = true }
        defer { Task { @MainActor in isLoading = false } }

        do {
            let reply = try await ServerAPIClient.sendChatMessage(text)
            let assistantMessage = ChatMessage(role: .assistant, content: reply)
            await MainActor.run { messages.append(assistantMessage) }
        } catch {
            let errorMessage = ChatMessage(role: .assistant, content: "Sorry, something went wrong: \(error.localizedDescription)")
            await MainActor.run { messages.append(errorMessage) }
        }
    }
}

