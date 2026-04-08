# Voice Interaction Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce widget voice interaction to "1 tap + speak" with silence-detection auto-submit, auto-dismiss, and Siri promotion.

**Architecture:** Rewrite `VoiceInputView` as a state-machine-driven view with silence detection replacing `isFinal`. Add `SiriTipView` to dashboard and Siri/Shortcuts settings section. No changes to ChatService, widget views, or intent logic.

**Tech Stack:** SwiftUI, Speech framework, AppIntents, SiriKit (SiriTipView)

**Worktree:** `/Users/jasongelman/claude-code/lutron-home/.worktrees/ios-widget/`
**iOS project:** `ios/LutronHome/LutronHome.xcodeproj`

---

### Task 1: Rewrite VoiceInputView with State Machine and Silence Detection

**Files:**
- Modify: `ios/LutronHome/LutronHome/ChatView.swift:299-433`

This is the core task. Replace the existing `VoiceInputView` with a state-machine-driven view that auto-submits after 1.5s of silence and auto-dismisses after success.

- [ ] **Step 1: Replace VoiceInputView with state machine implementation**

Replace everything from line 299 (`// MARK: - Voice Input View`) to the end of the file (line 433) with:

```swift
// MARK: - Voice Input View (for widget sheet)

struct VoiceInputView: View {
    @Environment(ChatService.self) var chatService
    @Environment(LutronStore.self) var store
    @Binding var isPresented: Bool

    enum ViewState {
        case listening
        case processing
        case done(String)
        case error(String)
    }

    @State private var viewState: ViewState = .listening
    @State private var transcribedText = ""
    @State private var input = ""
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    @State private var silenceTimer: Timer?
    @State private var noSpeechTimer: Timer?
    @State private var hasReceivedSpeech = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            mainContent
            Spacer()
            if !isDone {
                fallbackInput
            }
        }
        .onAppear { startListening() }
        .onDisappear { cleanup() }
    }

    private var isDone: Bool {
        if case .done = viewState { return true }
        return false
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        switch viewState {
        case .listening:
            listeningView
        case .processing:
            processingView
        case .done(let resultText):
            doneView(resultText)
        case .error(let errorText):
            errorView(errorText)
        }
    }

    // MARK: - Listening State

    private var listeningView: some View {
        HStack(spacing: 14) {
            WaveformView(animated: true)
                .frame(width: 30, height: 28)
            Text(transcribedText.isEmpty ? "Listening..." : "\"\(transcribedText)\"")
                .font(.body)
                .foregroundStyle(transcribedText.isEmpty ? Color.secondary : Color.primary)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Processing State

    private var processingView: some View {
        HStack(spacing: 14) {
            WaveformView(animated: false)
                .frame(width: 30, height: 28)
            Text("\"\(transcribedText)\"")
                .font(.body)
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Done State

    private func doneView(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .fontWeight(.medium)
            .foregroundStyle(Color.green)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    // MARK: - Error State

    private func errorView(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(Color.red)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    // MARK: - Fallback Text Input

    private var fallbackInput: some View {
        HStack(spacing: 8) {
            TextField("Or type a command...", text: $input)
                .font(.subheadline)
                .textFieldStyle(.roundedBorder)
                .onSubmit { sendManualInput() }

            Button {
                sendManualInput()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(input.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.orange)
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func sendManualInput() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        input = ""
        submitCommand(text)
    }

    private func submitCommand(_ text: String) {
        stopListening()
        viewState = .processing
        Task {
            await chatService.sendMessage(text, store: store)
            await MainActor.run {
                if let lastMessage = chatService.messages.last,
                   lastMessage.role == .assistant {
                    let content = lastMessage.content
                    if content.starts(with: "Sorry, something went wrong") {
                        viewState = .error(content)
                    } else {
                        viewState = .done(content)
                        // Auto-dismiss after 2 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isPresented = false
                        }
                    }
                } else {
                    viewState = .error("No response received")
                }
            }
        }
    }

    // MARK: - Speech Recognition

    private func startListening() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    viewState = .error("Microphone access denied. Enable it in Settings → Privacy → Speech Recognition.")
                    return
                }
                beginRecognition()
                startNoSpeechTimer()
            }
        }
    }

    private func beginRecognition() {
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

        recognitionTask = SFSpeechRecognizer()?.recognitionTask(with: request) { result, error in
            if let result {
                DispatchQueue.main.async {
                    transcribedText = result.bestTranscription.formattedString
                    hasReceivedSpeech = true
                    resetSilenceTimer()
                    cancelNoSpeechTimer()
                }
            }
            if error != nil {
                DispatchQueue.main.async {
                    if !hasReceivedSpeech {
                        // Recognition error before any speech — likely a transient issue
                    }
                    stopListening()
                }
            }
        }
    }

    // MARK: - Silence Detection

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            DispatchQueue.main.async {
                guard !transcribedText.isEmpty else { return }
                submitCommand(transcribedText)
            }
        }
    }

    // MARK: - No Speech Timeout

    private func startNoSpeechTimer() {
        noSpeechTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
            DispatchQueue.main.async {
                guard !hasReceivedSpeech else { return }
                stopListening()
                transcribedText = "No speech detected"
                // Stay in listening state but show the fallback input
            }
        }
    }

    private func cancelNoSpeechTimer() {
        noSpeechTimer?.invalidate()
        noSpeechTimer = nil
    }

    // MARK: - Cleanup

    private func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    private func cleanup() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        cancelNoSpeechTimer()
        stopListening()
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let animated: Bool

    private let barHeights: [CGFloat] = [6, 14, 22, 10, 18]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                WaveformBar(
                    baseHeight: barHeights[index],
                    animated: animated,
                    delay: Double(index) * 0.12
                )
            }
        }
    }
}

struct WaveformBar: View {
    let baseHeight: CGFloat
    let animated: Bool
    let delay: Double

    @State private var animating = false
    @State private var sweepActive = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(barColor)
            .frame(width: 3, height: currentHeight)
            .onAppear {
                if animated {
                    withAnimation(
                        .easeInOut(duration: 0.8)
                        .repeatForever(autoreverses: true)
                        .delay(delay)
                    ) {
                        animating = true
                    }
                } else {
                    // Sweep animation for processing state
                    withAnimation(
                        .easeInOut(duration: 1.5)
                        .repeatForever(autoreverses: true)
                        .delay(delay)
                    ) {
                        sweepActive = true
                    }
                }
            }
    }

    private var currentHeight: CGFloat {
        if animated {
            return animating ? (28 - baseHeight + 4) : baseHeight
        }
        return baseHeight
    }

    private var barColor: Color {
        if animated {
            return Color.orange
        }
        return sweepActive ? Color.orange : Color.gray
    }
}
```

- [ ] **Step 2: Update LutronHomeApp.swift to pass binding to VoiceInputView**

In `ios/LutronHome/LutronHome/LutronHomeApp.swift`, replace the sheet content (lines 53-66) with:

```swift
.sheet(isPresented: $showVoiceInput) {
    NavigationStack {
        VoiceInputView(isPresented: $showVoiceInput)
            .environment(store)
            .environment(chatService)
            .navigationTitle("Voice Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showVoiceInput = false }
                }
            }
    }
}
```

The only change is `VoiceInputView(isPresented: $showVoiceInput)` — passing the binding so the view can auto-dismiss itself.

- [ ] **Step 3: Build and verify**

```bash
cd /Users/jasongelman/claude-code/lutron-home/.worktrees/ios-widget/ios/LutronHome
xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd /Users/jasongelman/claude-code/lutron-home/.worktrees/ios-widget
git add ios/LutronHome/LutronHome/ChatView.swift ios/LutronHome/LutronHome/LutronHomeApp.swift
git commit -m "feat: rewrite VoiceInputView with silence-detection auto-submit and auto-dismiss"
```

---

### Task 2: Add SiriTipView to Dashboard

**Files:**
- Modify: `ios/LutronHome/LutronHome/ContentView.swift:292`

Add a `SiriTipView` below the `ChatCard()` on the dashboard to promote the "Tell Lutron Home a command" Siri shortcut.

- [ ] **Step 1: Add import and SiriTipView**

At the top of `ContentView.swift`, add the import:

```swift
import AppIntents
```

Then after line 292 (`ChatCard()`), add:

```swift
SiriTipView(intent: VoiceCommandIntent(), isVisible: $showSiriTip)
    .siriTipViewStyle(.automatic)
    .padding(.horizontal, -16)
```

Also add the state variable near the top of `ContentView` (after `@State private var selectedTab = 0`):

```swift
@State private var showSiriTip = true
```

- [ ] **Step 2: Build and verify**

```bash
cd /Users/jasongelman/claude-code/lutron-home/.worktrees/ios-widget/ios/LutronHome
xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
cd /Users/jasongelman/claude-code/lutron-home/.worktrees/ios-widget
git add ios/LutronHome/LutronHome/ContentView.swift
git commit -m "feat: add SiriTipView to dashboard for voice command discoverability"
```

---

### Task 3: Add Siri & Shortcuts Section to Settings

**Files:**
- Modify: `ios/LutronHome/LutronHome/SettingsView.swift`

Add a "Siri & Shortcuts" section between the "AI Assistant" section and the "Personalization" section (after line 431, before line 433).

- [ ] **Step 1: Add import**

At the top of `SettingsView.swift`, add:

```swift
import AppIntents
```

- [ ] **Step 2: Add the Siri & Shortcuts section**

After the closing of the "AI Assistant" `Section` (after line 431 `}`) and before the `// MARK: - For You Insights` comment (line 433), insert:

```swift
// MARK: - Siri & Shortcuts

Section {
    ShortcutsLink()
        .shortcutsLinkStyle(.automaticOutline)

    Button {
        addDictationShortcut()
    } label: {
        HStack {
            Image(systemName: "mic")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text("Add Voice Shortcut to Home Screen")
            Spacer()
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
        }
    }
} header: {
    Text("Siri & Shortcuts")
} footer: {
    Text("Use Siri hands-free: \"Hey Siri, tell Lutron Home to turn off the lights\". Or add a Home Screen shortcut for one-tap voice control.")
}
```

- [ ] **Step 3: Add the addDictationShortcut helper method**

Add this method inside the `SettingsView` struct, before the closing brace:

```swift
private func addDictationShortcut() {
    // Open Shortcuts app to create a new shortcut
    // The user can manually add "Dictate Text" → "Voice Command" actions
    if let url = URL(string: "shortcuts://create-shortcut") {
        UIApplication.shared.open(url)
    }
}
```

- [ ] **Step 4: Build and verify**

```bash
cd /Users/jasongelman/claude-code/lutron-home/.worktrees/ios-widget/ios/LutronHome
xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
cd /Users/jasongelman/claude-code/lutron-home/.worktrees/ios-widget
git add ios/LutronHome/LutronHome/SettingsView.swift
git commit -m "feat: add Siri & Shortcuts section to Settings"
```

---

### Task 4: Final Build Verification

**Files:** None (verification only)

- [ ] **Step 1: Clean build**

```bash
cd /Users/jasongelman/claude-code/lutron-home/.worktrees/ios-widget/ios/LutronHome
xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' clean build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Also build the widget extension to ensure no regressions**

```bash
cd /Users/jasongelman/claude-code/lutron-home/.worktrees/ios-widget/ios/LutronHome
xcodebuild -project LutronHome.xcodeproj -scheme LutronHomeWidgetExtension -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Verify all changes**

```bash
cd /Users/jasongelman/claude-code/lutron-home/.worktrees/ios-widget
git log --oneline -5
```

Expected: 3 new commits:
1. `feat: rewrite VoiceInputView with silence-detection auto-submit and auto-dismiss`
2. `feat: add SiriTipView to dashboard for voice command discoverability`
3. `feat: add Siri & Shortcuts section to Settings`
