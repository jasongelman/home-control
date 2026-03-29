import SwiftUI

// MARK: - Chat Card (inline on dashboard)

struct ChatCard: View {
    @Environment(ChatService.self) var chatService
    @Environment(LutronStore.self) var store
    @State private var expanded = false
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerButton
            if expanded {
                expandedContent
            }
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var headerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                expanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Home Assistant")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        Divider().overlay(Color.white.opacity(0.06))

        if !chatService.isConfigured {
            notConfiguredView
        } else {
            messageList
            Divider().overlay(Color.white.opacity(0.06))
            inputBar
        }
    }

    // MARK: - Not Configured

    private var notConfiguredView: some View {
        VStack(spacing: 8) {
            Image(systemName: "gear.badge.questionmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Set the server address in Settings to enable the chat assistant.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chatService.messages.isEmpty && !chatService.isLoading {
                        emptyState
                    }

                    ForEach(chatService.messages) { message in
                        MessageBubble(message: message)
                    }

                    if chatService.isLoading {
                        loadingIndicator
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(height: 240)
            .onChange(of: chatService.messages.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chatService.isLoading) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Ask me to control your home")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Try \"Turn off all the lights\" or \"What's on?\"")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var loadingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Thinking...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Describe what you'd like to do...", text: $input)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { sendMessage() }
                .disabled(chatService.isLoading)

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(inputTrimmed.isEmpty ? Color.secondary : Color.orange)
            }
            .disabled(inputTrimmed.isEmpty || chatService.isLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private var inputTrimmed: String {
        input.trimmingCharacters(in: .whitespaces)
    }

    private func sendMessage() {
        let text = inputTrimmed
        guard !text.isEmpty else { return }
        input = ""
        Task {
            await chatService.sendMessage(text, store: store)
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }
    private var bubbleBackground: Color {
        isUser ? Color.orange.opacity(0.12) : Color.white.opacity(0.04)
    }
    private var bubbleStroke: Color {
        isUser ? Color.orange.opacity(0.2) : Color.white.opacity(0.04)
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            bubbleContent
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Text(message.content)
                .font(.subheadline)
                .lineSpacing(2)

            if !message.actions.isEmpty {
                actionChips
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(bubbleStroke, lineWidth: 1)
        )
    }

    private var actionChips: some View {
        FlowLayout(spacing: 4) {
            ForEach(message.actions, id: \.description) { action in
                Text(action.description)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
    }
}
