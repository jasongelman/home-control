import SwiftUI
import Speech
import AVFoundation

struct ChatView: View {
    @Environment(LutronStore.self) var store
    var autoStartVoice: Bool = false

    @State private var messageText = ""
    @State private var messages: [(role: String, text: String)] = []
    @State private var isLoading = false

    // Speech recognition
    @State private var isListening = false
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()

    var body: some View {
        VStack(spacing: 0) {
            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "waveform.circle")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                                Text("Ask me to control your lights, shades, or scenes.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, msg in
                            MessageBubble(role: msg.role, text: msg.text)
                                .id(msg.offset)
                        }
                        if isLoading {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Thinking...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .id("loading")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) {
                    withAnimation {
                        if !messages.isEmpty {
                            proxy.scrollTo(messages.count - 1, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isLoading) {
                    if isLoading {
                        withAnimation { proxy.scrollTo("loading", anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 8) {
                TextField("Ask Lutron...", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .onSubmit { sendMessage() }

                // Mic button
                Button {
                    if isListening { stopListening() } else { startListening() }
                } label: {
                    Image(systemName: isListening ? "mic.fill" : "mic")
                        .foregroundStyle(isListening ? .red : .secondary)
                        .font(.system(size: 20))
                        .frame(width: 36, height: 36)
                }

                // Send button
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(messageText.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : .blue)
                }
                .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
        .onAppear {
            if autoStartVoice {
                startListening()
            }
        }
    }

    // MARK: - Send

    private func sendMessage() {
        let trimmed = messageText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        messageText = ""
        messages.append((role: "user", text: trimmed))
        isLoading = true

        Task {
            do {
                let reply = try await ServerAPIClient.sendChatMessage(trimmed)
                await MainActor.run {
                    messages.append((role: "assistant", text: reply))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    messages.append((role: "assistant", text: "Error: \(error.localizedDescription)"))
                    isLoading = false
                }
            }
        }
    }

    // MARK: - Speech Recognition

    private func startListening() {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { return }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try? audioEngine.start()

            DispatchQueue.main.async {
                isListening = true
            }

            recognitionTask = SFSpeechRecognizer()?.recognitionTask(with: request) { result, error in
                if let result {
                    DispatchQueue.main.async {
                        messageText = result.bestTranscription.formattedString
                    }
                    if result.isFinal {
                        stopListening()
                        DispatchQueue.main.async {
                            sendMessage()
                        }
                    }
                }
                if error != nil { stopListening() }
            }
        }
    }

    private func stopListening() {
        audioEngine.stop()
        if audioEngine.inputNode.numberOfInputs > 0 {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        DispatchQueue.main.async {
            isListening = false
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let role: String
    let text: String

    private var isUser: Bool { role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isUser ? Color.blue : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(isUser ? .white : .primary)
                .font(.body)
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

#Preview {
    NavigationStack {
        ChatView()
            .navigationTitle("Chat")
    }
}
