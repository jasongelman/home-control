# iOS Widget + Voice Control Design

## Overview

Add an iOS WidgetKit widget to the Lutron Home app that surfaces contextual recommended actions and provides voice-based home control via Siri and inline speech-to-text. Architected with App Intents (iOS 17+) to unify widget actions and Siri, with the design allowing Live Activities to be added later.

## Widget Sizes

### Small (2×2)
- **Header row**: "LUTRON HOME" label (left), mic icon (right, tappable)
- **Two recommendation slots**: stacked vertically with a subtle divider between them
- Each slot shows action name (e.g., "Evening Scene") and subtitle (e.g., "5 devices" or "Set to 80%")
- Tapping a slot executes the action immediately via AppIntent — no app launch, no confirmation

### Medium (4×2)
- **Header row**: "LUTRON HOME" label, status text ("3 lights on" / "All off"), mic icon
- **Bottom row** (side-by-side, separated by vertical dividers):
  - **Slot 1**: Top recommended action
  - **Slot 2**: Second recommended action
  - **Slot 3 (dynamic)**:
    - Default: Third recommended action
    - Override: If any appliance (dishwasher, washer, dryer) is running, shows appliance name + time remaining (e.g., "Dishwasher / 42 min left"). Slightly dimmer text, not tappable. If multiple appliances are running, shows the one finishing soonest.
  - **All Off button**: Lightbulb-slash icon + "All Off" label. Turns off all lights except Sebastian's Room.

### Visual Style
- Dark muted background (`linear-gradient(145deg, #1c1c1e, #2c2c2e)`), inspired by the iOS Weather widget
- No colored accents, badges, or icons on action items
- Typography-driven hierarchy: white at 0.92 opacity for action names, 0.35 for subtitles
- Mic icon and All Off button at 0.4–0.5 opacity — present but not attention-grabbing
- Subtle 0.08-opacity dividers between elements

## Recommendation Engine

### Input Signals
1. **Usage history** (from `UsageTracker`): time-bucketed frequency of device and scene usage over the last 30 days for the current time bucket (morning/afternoon/evening/night)
2. **Current device state** (from shared App Group data): what's currently on/off
   - Don't suggest turning on something that's already on at the expected level
   - Prefer "turn off" actions for devices that are on outside their typical usage window
   - Don't suggest activating a scene if all its target devices are already at their scene levels

### Output
- Ranked list of 2–3 `SuggestedAction` items, each with:
  - `type`: `device` or `scene`
  - `id`: device integration ID or scene ID
  - `label`: display name
  - `subtitle`: context string (e.g., "5 devices", "Set to 80%", "Turn off")

### Action Types
- **Scene activation**: activate a saved `LightScene` by ID
- **Device set level**: set a specific device to a target level (including 0 for off)

## Data Sharing (App Group)

Shared via `UserDefaults(suiteName: "group.com.jasongelman.LutronHome")`:

- **Device state snapshot**: `[Int: DeviceState]` — refreshed by the main app on every state change, read by the widget's `TimelineProvider`
- **Usage events**: `[UsageEvent]` — the existing usage log, written by the main app, read by the widget for recommendations
- **Scene list**: `[LightScene]` — current saved scenes
- **Appliance status**: Optional dishwasher/laundry state with remaining time
- **Light count**: Number of lights currently on (for the status line)

The main app calls `WidgetCenter.shared.reloadAllTimelines()` whenever device state, scenes, or appliance status changes.

## App Intents

All intents conform to `AppIntent` and live in a shared framework/module accessible to both the main app and the widget extension.

### `ActivateSceneIntent`
- Parameter: `sceneId: String`
- Reads scene targets from App Group, sends `setLevel` commands via LEAP
- Siri phrase: "Activate [scene name] in Lutron Home"

### `SetDeviceLevelIntent`
- Parameters: `deviceId: Int`, `level: Double`, `fadeTime: Double` (default 1.0)
- Sends `setLevel` via LEAP
- Siri phrase: "Set [device name] to [level] percent in Lutron Home"

### `AllLightsOffIntent`
- No parameters
- Reads all light devices from App Group, sets each to level 0, **excluding devices in Sebastian's Room**
- Siri phrase: "Turn off all lights in Lutron Home"

### `VoiceCommandIntent`
- Parameter: `spokenText: String`
- Routes to Anthropic API (ChatService logic) for interpretation
- Falls back to this for ambiguous Siri input that doesn't match structured intents
- Siri phrase: "Tell Lutron Home [free-form text]"

## Voice Input

### Inline (Widget Mic Button)
- Tapping the mic icon in the widget opens a compact UI (via App Intent / intermediate app scene) that:
  1. Activates `SFSpeechRecognizer` for live transcription
  2. On completion, sends transcribed text through the same ChatService logic (Anthropic API with tool use)
  3. Executes resulting actions (set device levels, activate scenes)
  4. Shows brief confirmation, then dismisses

### Siri Integration
- `AppShortcutsProvider` registers all intents with suggested phrases
- Direct commands (set level, activate scene, all off) resolve to structured intents
- Open-ended commands ("Tell Lutron Home I'm heading to bed") route to `VoiceCommandIntent` → Claude

## LEAP Communication from Widget/Intent

Widget extensions can't hold persistent LEAP (TLS) connections. Two options:

**Approach: Server relay (recommended)**
- Intents make HTTP calls to the existing Node.js server's REST API (`/api/devices/:id`, `/api/scenes/:id/activate`)
- Server already handles LEAP connections and state management
- Widget reads state from App Group (populated by the main app's WebSocket connection)
- Requires the server to be reachable (same network or VPN)

**Fallback: Direct LEAP from intent (future consideration)**
- Short-lived LEAP connection from the intent process using bundled certificates
- Higher latency, more complex, but works without the server

## Architecture for Future Live Activities

The design supports adding Live Activities later:
- The App Group data sharing layer is the same — Live Activities would read from the same shared container
- `ActivityKit` would use the same `AppIntent` actions for interactive controls
- The recommendation engine logic can be extracted into a shared framework used by both the widget `TimelineProvider` and a future `ActivityAttributes` update cycle

## New Xcode Targets & Files

### Widget Extension Target: `LutronHomeWidget`
- `LutronHomeWidget.swift` — Widget definition, entry point, `WidgetBundle`
- `SmallWidgetView.swift` — Small widget SwiftUI view
- `MediumWidgetView.swift` — Medium widget SwiftUI view
- `WidgetTimelineProvider.swift` — `TimelineProvider` that reads App Group data and runs recommendation logic
- `RecommendationEngine.swift` — Pure logic: takes usage events + device state + time → ranked actions
- `Info.plist` — Widget extension config

### Shared (accessible to both app and extension)
- `AppGroupManager.swift` — Read/write helpers for the shared App Group container
- `SuggestedAction.swift` — Model for recommended actions
- App Intents:
  - `ActivateSceneIntent.swift`
  - `SetDeviceLevelIntent.swift`
  - `AllLightsOffIntent.swift`
  - `VoiceCommandIntent.swift`
  - `AppShortcutsProvider.swift` — Registers Siri phrases

### Main App Changes
- `LutronStore.swift` — Write device state, scenes, appliance status to App Group on every change; call `WidgetCenter.shared.reloadAllTimelines()`
- `UsageTracker.swift` — Write events to App Group in addition to local UserDefaults
- `LutronHome.entitlements` — Add App Group capability
- `LutronHomeWidget.entitlements` — Add App Group capability
