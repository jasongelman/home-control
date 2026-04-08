# Voice Interaction Redesign

## Goal

Reduce the widget voice interaction from "tap mic → dictate → tap submit → wait → dismiss" to "tap mic → speak → done" by adding silence-detection auto-submit, confirmation display, and auto-dismiss. Additionally, promote Siri and Shortcuts as zero-tap alternatives.

## Architecture

The redesign touches three areas: the in-app VoiceInputView (rewrite with state machine and silence detection), Siri discoverability (SiriTipView + Settings rows), and an installable Apple Shortcut (dictation → VoiceCommandIntent). No changes to the widget itself, ChatService, or VoiceCommandIntent.

## Part 1: Streamlined VoiceInputView

### State Machine

VoiceInputView becomes a three-state view:

- **`.listening`** — Animated waveform bars (orange, bouncing) + live transcription text displayed horizontally centered. Text input field at bottom as fallback.
- **`.processing`** — Same waveform shape but frozen; orange color sweeps across bars left-to-right repeatedly (grey → orange → grey). Transcribed text shown in muted color.
- **`.done`** — Action result text displayed in green (e.g., "Office light set to 100%"). Auto-dismisses after 2 seconds.
- **`.error`** — Error text displayed in red (e.g., "Couldn't reach server"). Does NOT auto-dismiss. User must manually close.

All states use the same fixed-size sheet — no resizing between states.

### Silence Detection

Replace reliance on `SFSpeechRecognizer`'s unreliable `isFinal` with a timer-based approach:

1. On each new partial transcription result from the speech recognizer, reset a 1.5-second `Timer`.
2. Do not start the timer until at least one partial result has been received (prevents premature submit during initial silence before user speaks).
3. When the timer fires (1.5s of silence after speech), auto-submit the current transcription text.
4. If no speech is detected for 10 seconds after the view appears, show "No speech detected" in grey and surface the text input fallback.

### Auto-Dismiss

1. After `ChatService.sendMessage` returns successfully, transition to `.done` state.
2. Display the response text (from Claude's reply) in green.
3. After 2 seconds, dismiss the sheet programmatically (`showVoiceInput = false`).
4. On error, transition to `.error` state and remain open.

### Fallback Text Input

The text field and submit button remain at the bottom of the view in all states except `.done`. They are visually secondary (smaller, muted) but functional for cases where speech recognition fails or the user prefers typing.

## Part 2: Siri Promotion

Three layers of progressive Siri discoverability:

### SiriTipView on Dashboard

Add a `SiriTipView` (iOS 17+ native component) to the main dashboard, associated with `VoiceCommandIntent`. Displays a system-styled suggestion like "Try saying 'Hey Siri, tell Lutron Home to turn off the lights'". One-time display, user-dismissable. Apple handles all styling.

### Settings → Siri & Shortcuts Section

Add a new section in `SettingsView` with two rows:

1. **"Set Up Siri"** — Uses `ShortcutsLink` to open the system Siri shortcut setup flow for the `VoiceCommandIntent`. Lets users configure their own trigger phrase.
2. **"Add to Shortcuts"** — Creates/shares a pre-built Apple Shortcut that chains: system "Dictate Text" action → passes result to `VoiceCommandIntent`. This gives users a Home Screen icon for one-tap voice control.

### Home Screen Shortcut

The installable shortcut appears as a plain icon on the Home Screen (grey background, standard mic icon, no color). Label: "Lutron Voice". Flow: tap icon → Shortcuts app opens → system dictation UI → transcription passed to VoiceCommandIntent → confirmation dialog.

## Part 3: Error & Edge Cases

| Scenario | Behavior |
|----------|----------|
| Command succeeds | Green result text, auto-dismiss after 2s |
| Command fails (server error, API error) | Red error text, stays open, user dismisses manually |
| No speech detected for 10s | Grey "No speech detected" text, text input field highlighted as fallback |
| Speech recognition authorization denied | Show message directing user to Settings, text input available |
| User taps Done/close during any state | Immediately dismiss sheet, cancel any in-flight request |

## Files to Modify

- `LutronHome/ChatView.swift` — Rewrite `VoiceInputView` with state machine, silence detection, auto-dismiss
- `LutronHome/LutronHomeApp.swift` — Add auto-dismiss binding, add SiriTipView to dashboard
- `LutronHome/SettingsView.swift` — Add "Siri & Shortcuts" section with two rows
- `LutronHome/Intents/VoiceCommandIntent.swift` — No logic changes; used by SiriTipView and Shortcut

## Files NOT Modified

- Widget views (SmallWidgetView, MediumWidgetView) — mic button stays as-is
- ChatService.swift — no changes to API/tool logic
- AppGroupManager.swift — no changes to data sharing
- Other App Intents (ActivateSceneIntent, SetDeviceLevelIntent, AllLightsOffIntent)

## Out of Scope

- Changing the widget layout or button arrangement
- Multi-command follow-up conversations from the voice sheet
- Changing how ChatService processes commands or calls the Anthropic API
- Custom Siri UI or SiriKit domains
