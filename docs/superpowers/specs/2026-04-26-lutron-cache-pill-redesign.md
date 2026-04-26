# Lutron Device Caching + Pill Redesign

## Summary

Three changes shipped together:

1. **Cache Lutron device topology to disk** so the app doesn't re-fetch every device on each foreground transition. Add a manual "Refresh Devices" button in Settings.
2. **Consolidate Settings sections** — merge "Processor Connection" and "Status" into a single "Lutron" section.
3. **Redesign light and shade pills** — unified drag-to-control pill with a visible vertical line affordance, single-tap toggle, no room navigation on pill tap.

---

## 1. Lutron Device Caching

### Problem

`LutronStore.connect()` calls `loadTopology()` on every connection, which fetches all areas + all zones from the LEAP processor. This runs on every foreground transition (scenePhase → active). The device list rarely changes — topology re-fetch is unnecessary overhead and delays the UI.

### Solution

Save the device topology (names, rooms, types, integration IDs, partition IDs — NOT levels) to a JSON file in the Documents directory. On launch/reconnect, load from cache and skip topology fetch. Only subscribe to `/zone/status` for real-time level updates.

### Cache file

`Documents/lutron-topology.json` — same pattern as `alarm-topology.json` used by TotalConnectManager.

Contents:
```json
{
  "devices": [
    {
      "integrationId": 42,
      "name": "Kitchen Pendants",
      "type": "light",
      "category": "light",
      "room": "Kitchen",
      "components": null
    }
  ],
  "processorHost": "192.168.1.191",
  "savedAt": 1714150000
}
```

The `processorHost` field ensures the cache is invalidated if the user switches processors.

### Flows

**Cold start (cache exists, same host):**
1. Load cached topology into `devices` dict with level = 0 (unknown)
2. Connect to LEAP
3. Subscribe to `/zone/status` — levels fill in as status messages arrive
4. UI shows device names/rooms immediately; levels appear within ~1s

**Cold start (no cache or different host):**
1. Full `loadTopology()` as today
2. Save cache on completion

**Foreground resume (already connected):**
1. No action — subscription is already active

**Foreground resume (disconnected):**
1. Reconnect to LEAP
2. Subscribe to `/zone/status` (topology already in memory from cache)
3. No topology re-fetch

**Manual refresh (Settings button):**
1. Full `loadTopology()` re-fetch
2. Overwrite cache
3. Re-subscribe to status updates

### LutronStore changes

- Add `loadCachedTopology()` / `saveCachedTopology()` / `deleteCachedTopology()` (private, Documents dir)
- `connect()`: if cache exists and host matches, skip `loadTopology()`, go straight to zone status subscription
- Add public `refreshDevices()`: force full `loadTopology()` + save cache
- `saveCachedTopology()` called at end of `loadTopology()` on success
- `disconnect()` does NOT delete cache (it persists across sessions)

---

## 2. Settings Consolidation

### Current

Two sections:
- **Processor Connection**: IP text field + Reconnect button
- **Status**: Connected/Disconnected indicator, device count, lights on count

### New

Single section titled **"Lutron"**:
1. Processor IP text field + Reconnect button (unchanged)
2. Connection status row (green/red dot + "Connected"/"Disconnected")
3. Device count row
4. "Refresh Devices" button — calls `store.refreshDevices()`, disabled when not connected

### Files

- `SettingsView.swift`: Merge the two sections, rename header, add Refresh button

---

## 3. Unified Pill Redesign (Lights + Shades)

### Design goals

- Visible drag affordance (vertical line) so the drag-to-control interaction is discoverable
- Single tap to toggle on/off
- Pill tap does NOT navigate to room detail — room name header does that instead
- Match the editorial aesthetic of the climate section (clean, minimal, no heavy rounded corners)
- Same pill component for both lights and shades
- The device name stays left aligned and the fill moves from the left edge to the right edge depending on the dim level

### Pill anatomy

```
When off (0%):
+--------------------------------------------------+
|| Device Name                                 0%  |
+--------------------------------------------------+
 ^ orange vertical line at left edge

When on at ~47%:
+--------------------------------------------------+
|===================| Device Name             47%  |
+--------------------------------------------------+
                     ^ draggable vertical line

When on at 100%:
+--------------------------------------------------+
|=============================================|100% |
+--------------------------------------------------+
                                               ^ line at right edge
```

### Dimensions and styling

- **Height**: ~40pt (same as current light pills)
- **Corner radius**: 0-2pt (sharp, not the current rounded style)
- **Background**: `EditorialTheme.cardBackground`
- **Border**: 0.5pt stroke, `EditorialTheme.cardBorder`
- **Fill**: Orange (`EditorialTheme.accent`) at 0.15 opacity, from left edge to line position
- **Vertical line**: 2pt wide, solid `EditorialTheme.accent`, full pill height
- **Device name**: Uppercase, 10pt semibold, tracking 0.6pt
- **Level %**: Mono font, 12pt, `EditorialTheme.accent` when on, `.secondary` when off

### Interaction

- **Drag** (horizontal): Move the vertical line to change level. Updates device in real-time with throttling (existing `sendIfNeeded` pattern). Snaps to nearest 5% on release.
- **Single tap** (anywhere on pill): If level > 0, turn off (set to 0). If level == 0, turn on (set to 100).
- **Drag vs scroll detection**: Reuse existing pattern — detect horizontal vs vertical intent with minimumDistance threshold.

### Shades

Identical pill. Position 0% = closed, 100% = open. Replaces the current CLOSE/HALF/OPEN button layout. Fade time of 2s on shade commands (existing behavior).

### Room headers

- Room name text in the section header is tappable — navigates to `RoomDetailView`
- This is the only way to reach the room view from the lights/shades pages

### Page-level changes

- Remove rounded corners from pill containers
- Both `EditorialLightsSection` and `EditorialShadesSection` use the same pill view component

### Shared component

Extract a new `DimmablePill` view (or similar name) used by both lights and shades sections. Props:
- `device: DeviceState`
- `onLevelChange: (Double) -> Void`
- `onToggle: () -> Void`

---

## Files Changed

| File | Change |
|------|--------|
| `LutronStore.swift` | Add topology cache (save/load/delete), modify `connect()` to use cache, add `refreshDevices()` |
| `SettingsView.swift` | Merge "Processor Connection" + "Status" into "Lutron", add "Refresh Devices" button |
| `EditorialLightsSection.swift` | Replace `EditorialLightRow` with shared `DimmablePill`, remove room navigation on pill tap, ensure room header navigates to room detail, remove rounded corners |
| `EditorialShadesSection.swift` | Replace preset buttons with `DimmablePill`, remove rounded corners |
| `ContentView.swift` | Any wiring changes needed for room header navigation |

No new files are strictly required — `DimmablePill` can live in `EditorialLightsSection.swift` since that's its primary home, or be extracted to its own file if the shared component warrants it.

---

## Out of Scope

- Keypad pill redesign (separate effort)
- Web client parity for pill redesign (server/web changes)
- Widget changes
