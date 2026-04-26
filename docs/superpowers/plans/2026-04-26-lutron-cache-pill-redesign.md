# Lutron Device Caching + Pill Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cache Lutron device topology to disk, consolidate Settings sections, and redesign light/shade pills with a drag-to-dim vertical line affordance.

**Architecture:** Three independent changes: (1) LutronStore gets topology cache persistence using the same Documents-directory pattern as TotalConnectManager, (2) SettingsView merges two sections into one "Lutron" section with a Refresh Devices button, (3) a shared `DimmablePill` view replaces both `EditorialLightRow` and the shade card preset buttons with a unified drag-to-control pill.

**Tech Stack:** SwiftUI, Observation framework, LEAP protocol, JSON file persistence

---

### Task 1: Add topology caching to LutronStore

**Files:**
- Modify: `ios/LutronHome/LutronHome/LutronStore.swift`

This task adds save/load/delete for the device topology cache, modifies `connect()` to use the cache when available, and adds a public `refreshDevices()` method.

- [ ] **Step 1: Add cache data structure and file URL**

Add these after the `maxReconnectDelay` property (around line 38) in `LutronStore`:

```swift
    // MARK: - Topology Cache

    private struct CachedTopology: Codable {
        var devices: [DeviceState]
        var processorHost: String
        var savedAt: Double
    }

    private var topologyCacheURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("lutron-topology.json")
    }

    /// True if we loaded topology from cache and haven't done a full LEAP fetch yet.
    private var usingCachedTopology = false
```

- [ ] **Step 2: Add save/load/delete methods**

Add these after the `topologyCacheURL` property:

```swift
    private func loadCachedTopology() -> Bool {
        guard let url = topologyCacheURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CachedTopology.self, from: data),
              cache.processorHost == processorHost,
              !cache.devices.isEmpty else {
            return false
        }
        // Load devices with level = 0 (unknown until status subscription delivers)
        var newDevices: [Int: DeviceState] = [:]
        for var d in cache.devices {
            d.level = 0
            d.lastUpdated = Date().timeIntervalSince1970
            newDevices[d.integrationId] = d
        }
        devices = newDevices
        usingCachedTopology = true
        print("LEAP: loaded \(newDevices.count) devices from topology cache")
        return true
    }

    private func saveCachedTopology() {
        guard let url = topologyCacheURL else { return }
        let cache = CachedTopology(
            devices: Array(devices.values),
            processorHost: processorHost,
            savedAt: Date().timeIntervalSince1970
        )
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
            print("LEAP: saved topology cache (\(devices.count) devices)")
        } catch {
            print("LEAP: failed to write topology cache — \(error.localizedDescription)")
        }
    }

    private func deleteCachedTopology() {
        guard let url = topologyCacheURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
```

- [ ] **Step 3: Add `refreshDevices()` public method**

Add this after the existing `refresh()` method:

```swift
    /// Force a full topology re-fetch from the LEAP processor, ignoring cache.
    func refreshDevices() async {
        guard leapClient != nil else {
            connect()
            return
        }
        usingCachedTopology = false
        await loadTopology()
    }
```

- [ ] **Step 4: Modify `connect()` to use cache**

Change the `client.onConnect` closure in `connect()` from:

```swift
        client.onConnect = { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.reconnectAttempt = 0
            self.updateConnectionState()
            self.statusMessage = "Connected, loading devices..."
            print("LEAP: connected to \(self.processorHost)")
            Task { await self.loadTopology() }
        }
```

to:

```swift
        client.onConnect = { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.reconnectAttempt = 0
            self.updateConnectionState()
            print("LEAP: connected to \(self.processorHost)")
            if self.usingCachedTopology || !self.devices.isEmpty {
                // Topology already in memory (from cache or prior session) —
                // just subscribe for real-time level updates.
                self.statusMessage = "Subscribing to updates..."
                Task { await self.subscribeToZoneStatus() }
            } else {
                self.statusMessage = "Connected, loading devices..."
                Task { await self.loadTopology() }
            }
        }
```

- [ ] **Step 5: Load cache in `start()`**

Change `start()` from:

```swift
    func start() {
        guard !started else { return }
        started = true
        startNetworkMonitoring()
        connect()
    }
```

to:

```swift
    func start() {
        guard !started else { return }
        started = true
        _ = loadCachedTopology()
        startNetworkMonitoring()
        connect()
    }
```

- [ ] **Step 6: Extract `subscribeToZoneStatus()` from `loadTopology()`**

Add a new method that subscribes and populates initial levels. This is the code from step 4 of `loadTopology()` (lines 268-284 plus the subscribe from QSX path), extracted so it can be called independently:

```swift
    /// Subscribe to /zone/status for real-time level updates. Also applies
    /// the initial status snapshot returned by the SubscribeRequest.
    private func subscribeToZoneStatus() async {
        guard let client = leapClient else { return }
        do {
            let subResp = try await client.send(LEAPMessagePayload(
                CommuniqueType: "SubscribeRequest",
                Header: LEAPMessageHeader(Url: "/zone/status")
            ))
            if let statuses = subResp.Body?.ZoneStatuses {
                await MainActor.run {
                    for zs in statuses {
                        let zoneHref = zs["Zone"]?.dictValue?["href"]?.stringValue ?? ""
                        let zid = self.hrefToId(zoneHref)
                        let level = zs["Level"]?.doubleValue ?? 0
                        if zid > 0 { self.devices[zid]?.level = level }
                    }
                    self.statusMessage = "\(self.devices.count) devices"
                }
            }
            syncToAppGroup()
            print("LEAP: subscribed to zone status updates")
        } catch {
            print("LEAP: subscribe failed: \(error)")
            await MainActor.run { self.statusMessage = "Subscribe failed: \(error.localizedDescription)" }
        }
    }
```

- [ ] **Step 7: Save cache at end of `loadTopology()`**

In `loadTopology()`, add `saveCachedTopology()` right after `syncToAppGroup()` (around line 289):

```swift
            syncToAppGroup()
            saveCachedTopology()
```

Also set `usingCachedTopology = false` at the top of `loadTopology()` (after the `isLoading = true` line):

```swift
        usingCachedTopology = false
```

- [ ] **Step 8: Replace inline subscribe with `subscribeToZoneStatus()` call**

In `loadTopology()`, replace the zone status subscription block (lines 268-285, the `if initialLevels.isEmpty` block) with:

```swift
            // Subscribe to zone status updates (if not already from QSX path)
            if initialLevels.isEmpty {
                await subscribeToZoneStatus()
            }
```

Remove the old inline subscribe code and the redundant status message update — `subscribeToZoneStatus()` handles both.

Also remove the final `await MainActor.run { statusMessage = "..." }` and `print("LEAP: fully connected...")` since `subscribeToZoneStatus()` now sets the status message. Keep `syncToAppGroup()` and add `saveCachedTopology()` after it.

- [ ] **Step 9: Build and verify**

Run:
```bash
cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 10: Commit**

```bash
git add ios/LutronHome/LutronHome/LutronStore.swift
git commit -m "feat: cache Lutron device topology to disk

Skip full LEAP topology fetch on reconnect when cache exists.
Devices appear instantly with level=0, then fill in from zone
status subscription. Add refreshDevices() for manual re-fetch."
```

---

### Task 2: Consolidate Settings sections

**Files:**
- Modify: `ios/LutronHome/LutronHome/SettingsView.swift`

- [ ] **Step 1: Replace "Processor Connection" and "Status" sections**

Replace lines 32-71 (both sections) with:

```swift
            Section("Lutron") {
                TextField("Processor IP Address", text: $host)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("Reconnect") {
                    store.processorHost = host
                    store.connect()
                }
                .tint(.orange)

                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(store.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(store.isConnected ? "Connected" : "Disconnected")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Devices")
                    Spacer()
                    Text("\(store.devices.count)")
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await store.refreshDevices() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh Devices")
                    }
                }
                .disabled(!store.isConnected)
                .tint(.orange)
            }
```

- [ ] **Step 2: Build and verify**

Run:
```bash
cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add ios/LutronHome/LutronHome/SettingsView.swift
git commit -m "feat: consolidate Processor Connection + Status into Lutron section

Merge the two settings sections, add Refresh Devices button that
triggers a full topology re-fetch from the LEAP processor."
```

---

### Task 3: Create shared DimmablePill view

**Files:**
- Modify: `ios/LutronHome/LutronHome/EditorialLightsSection.swift`

The `DimmablePill` replaces `EditorialLightRow` and will also be used by the shades section. It lives in `EditorialLightsSection.swift` since that's the primary consumer and avoids creating a new file.

- [ ] **Step 1: Replace EditorialLightRow with DimmablePill**

Replace the entire `EditorialLightRow` struct (lines 45-170) and the `LightDragIntent` enum (line 3) with:

```swift
private enum DragIntent { case undecided, adjusting, scrolling }

struct DimmablePill: View {
    @Environment(LutronStore.self) var store
    let device: DeviceState
    var fadeTime: Double? = nil

    @State private var dragIntent: DragIntent = .undecided
    @State private var isDragging = false
    @State private var dragLevel: Double = 0
    @State private var lastSentLevel: Double = -1
    @State private var lastSendTime: Date = .distantPast

    private var displayLevel: Double { isDragging ? dragLevel : device.level }
    private var isOn: Bool { displayLevel > 0 }

    private func sendIfNeeded(_ level: Double) {
        let snapped = (level / 5).rounded() * 5
        let now = Date()
        guard abs(snapped - lastSentLevel) >= 5,
              now.timeIntervalSince(lastSendTime) >= 0.1 else { return }
        lastSentLevel = snapped
        lastSendTime = now
        store.setLevel(device.integrationId, level: snapped, fadeTime: fadeTime ?? 0)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(EditorialTheme.cardBackground)

                // Fill bar from left edge to current level
                Rectangle()
                    .fill(EditorialTheme.accent.opacity(0.15))
                    .frame(width: geo.size.width * (displayLevel / 100))
                    .animation(isDragging ? nil : .easeOut(duration: 0.15), value: displayLevel)

                // Vertical line at current level position
                Rectangle()
                    .fill(EditorialTheme.accent)
                    .frame(width: 2)
                    .offset(x: geo.size.width * (displayLevel / 100) - 1)
                    .animation(isDragging ? nil : .easeOut(duration: 0.15), value: displayLevel)

                // Border
                Rectangle()
                    .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)

                // Content — name left-aligned, percentage right-aligned
                HStack(spacing: 6) {
                    Text(device.name.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(EditorialTheme.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text("\(Int(displayLevel))%")
                        .font(EditorialTheme.monoValue(size: 12))
                        .foregroundStyle(isOn ? EditorialTheme.accent : EditorialTheme.secondaryText)
                }
                .padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                let newLevel: Double = device.level > 0 ? 0 : 100
                store.setLevel(device.integrationId, level: newLevel, fadeTime: fadeTime ?? 1)
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if dragIntent == .undecided {
                            let h = abs(value.translation.width)
                            let v = abs(value.translation.height)
                            if h > v * 1.5 { dragIntent = .adjusting }
                            else if v > h * 1.5 { dragIntent = .scrolling }
                        }
                        guard dragIntent == .adjusting else { return }
                        if !isDragging {
                            isDragging = true
                            dragLevel = device.level
                            lastSentLevel = device.level
                        }
                        let pct = max(0, min(100, (value.location.x / geo.size.width) * 100))
                        dragLevel = pct
                        sendIfNeeded(pct)
                    }
                    .onEnded { value in
                        if dragIntent == .adjusting && isDragging {
                            let pct = max(0, min(100, (value.location.x / geo.size.width) * 100))
                            let snapped = (pct / 5).rounded() * 5
                            store.setLevel(device.integrationId, level: snapped, fadeTime: fadeTime ?? 0)
                        }
                        dragIntent = .undecided
                        isDragging = false
                    }
            )
        }
        .frame(height: 40)
    }
}
```

Key differences from old `EditorialLightRow`:
- `Rectangle()` instead of `RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)` — sharp corners
- No colored dot, no X button
- Added vertical line at level position
- `onTapGesture` toggles on/off instead of navigating
- `fadeTime` parameter for shade commands (defaults to 0 for lights, 2 for shades)
- Drag range is 0-100 (not 1-100) so dragging fully left turns off
- Device name used directly (no room-prefix stripping — that happens at the section level)

- [ ] **Step 2: Update EditorialLightsSection to use DimmablePill**

Replace the `EditorialLightsSection` body (lines 5-41) with:

```swift
struct EditorialLightsSection: View {
    @Environment(LutronStore.self) var store

    var body: some View {
        let lights = store.lightsOn
        if !lights.isEmpty {
            VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                EditorialSectionHeader(
                    title: "LIGHTS ON",
                    trailing: "\(lights.count) ACTIVE"
                )

                let byRoom = Dictionary(grouping: lights, by: \.room)
                let sortedRooms = byRoom.keys.sorted()

                ForEach(sortedRooms, id: \.self) { room in
                    let roomLights = byRoom[room]!
                    VStack(alignment: .leading, spacing: 6) {
                        Text(room.uppercased())
                            .font(.system(size: 9, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(EditorialTheme.secondaryText)

                        ForEach(roomLights) { device in
                            DimmablePill(device: device)
                        }
                    }
                }
            }
        }
    }
}
```

Changes from old version:
- Removed `LazyVGrid` 2-column layout — pills are now full-width, single column
- Uses `DimmablePill` instead of `EditorialLightRow`
- Room name header is plain text (not tappable here — homepage section; room navigation via CategoryTab headers)

- [ ] **Step 3: Build and verify**

Run:
```bash
cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add ios/LutronHome/LutronHome/EditorialLightsSection.swift
git commit -m "feat: replace light pills with DimmablePill

Unified pill with visible vertical line drag affordance, single-tap
toggle, sharp corners, full-width layout. No room navigation on tap."
```

---

### Task 4: Update EditorialShadesSection to use DimmablePill

**Files:**
- Modify: `ios/LutronHome/LutronHome/EditorialShadesSection.swift`

- [ ] **Step 1: Rewrite EditorialShadesSection**

Replace the entire file content with:

```swift
import SwiftUI

struct EditorialShadesSection: View {
    @Environment(LutronStore.self) var store

    var body: some View {
        let shadeRooms = self.shadeRooms
        if !shadeRooms.isEmpty {
            VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                EditorialSectionHeader(
                    title: "SHADES",
                    trailing: "\(shadeRooms.flatMap(\.shades).count) DEVICES"
                )

                ForEach(shadeRooms, id: \.name) { room in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(room.name.uppercased())
                            .font(.system(size: 9, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(EditorialTheme.secondaryText)

                        ForEach(room.shades) { shade in
                            DimmablePill(device: shade, fadeTime: 2)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data

    private struct ShadeRoom {
        let name: String
        let shades: [DeviceState]
    }

    private var shadeRooms: [ShadeRoom] {
        let shadeDevices = store.devices.values.filter { $0.category == .shadesAndDrapes }
        let grouped = Dictionary(grouping: shadeDevices, by: \.room)
        return grouped.map { ShadeRoom(name: $0.key, shades: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name < $1.name }
    }
}
```

Changes from old version:
- Removed `primaryRooms` filter — shows all shade rooms
- Removed `shadeCard` with CLOSE/HALF/OPEN buttons
- Uses `DimmablePill` with `fadeTime: 2` for smooth shade movement
- Full-width single-column layout matching the lights section
- Simplified header ("SHADES" instead of "SHADES · PRIMARY")

- [ ] **Step 2: Build and verify**

Run:
```bash
cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add ios/LutronHome/LutronHome/EditorialShadesSection.swift
git commit -m "feat: replace shade preset buttons with DimmablePill

Shades now use the same drag-to-control pill as lights, with 2s fade
time. Shows all shade rooms instead of filtering to primary only."
```

---

### Task 5: Add room-header navigation in CategoryTab

**Files:**
- Modify: `ios/LutronHome/LutronHome/ContentView.swift`

The `CategoryRoomCard` currently wraps the entire card in a `Button(action: onTap)` that navigates to the room. Since `DimmablePill` handles its own interactions now, we need the room name header in the lights/shades tab to be the navigation point to `RoomDetailView`.

- [ ] **Step 1: Update `floorSection` room cards for lights tab**

In the `floorSection` method (around line 220), the rooms are rendered as `CategoryRoomCard` inside a `MasonryTwoColumn`. For the lights tab (single-category `.light`), we want a different layout: room name headers with `DimmablePill` rows instead of `CategoryRoomCard`.

Replace the `floorSection` method:

```swift
    private func floorSection(floor: Floor, rooms: [(name: String, devices: [DeviceState])]) -> some View {
        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
            EditorialSectionHeader(
                title: floor.rawValue,
                trailing: "\(rooms.flatMap(\.devices).count) DEVICES"
            )

            if isLightsOrShadesTab {
                // Lights & shades: full-width pills grouped by room with tappable headers
                ForEach(rooms, id: \.name) { room in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { selectedRoom = room.name } label: {
                            HStack(spacing: 4) {
                                Text(room.name.uppercased())
                                    .font(.system(size: 9, weight: .medium))
                                    .tracking(0.8)
                                    .foregroundStyle(EditorialTheme.secondaryText)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7, weight: .semibold))
                                    .foregroundStyle(EditorialTheme.tertiaryText)
                            }
                        }
                        .buttonStyle(.plain)

                        ForEach(room.devices) { device in
                            let fade: Double? = device.category == .shadesAndDrapes ? 2 : nil
                            DimmablePill(device: device, fadeTime: fade)
                        }
                    }
                }
            } else {
                // Other categories: room cards with masonry layout
                MasonryTwoColumn(spacing: EditorialTheme.gridSpacing) {
                    ForEach(rooms, id: \.name) { room in
                        CategoryRoomCard(
                            name: room.name,
                            devices: room.devices,
                            category: room.devices.first?.category ?? categories.first ?? .light,
                            onTap: { selectedRoom = room.name }
                        )
                    }
                }
            }
        }
    }
```

- [ ] **Step 2: Add `isLightsOrShadesTab` computed property**

Add this next to the existing `isLightsTab` property (around line 100):

```swift
    private var isLightsOrShadesTab: Bool {
        categories.count == 1 && (categories[0] == .light || categories[0] == .shadesAndDrapes)
    }
```

- [ ] **Step 3: Build and verify**

Run:
```bash
cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add ios/LutronHome/LutronHome/ContentView.swift
git commit -m "feat: use DimmablePill in lights/shades category tabs

Room headers in lights and shades tabs are tappable to navigate to
RoomDetailView. Individual pills handle their own drag/tap interactions."
```

---

### Task 6: Final build verification

- [ ] **Step 1: Full clean build**

Run:
```bash
cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' clean build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 2: Verify no warnings about unused code**

Check that:
- `EditorialLightRow` is fully removed (no references)
- `shadeCard`, `shadeButton`, `primaryRooms` are fully removed from `EditorialShadesSection`
- `DimmablePill` is accessible from both `EditorialLightsSection` and `EditorialShadesSection` (it's `internal` access, not `private`)

If `DimmablePill` has `private` access (from the old `EditorialLightRow`), change it to `internal` (remove the `private` keyword) so `EditorialShadesSection` and `ContentView` can use it.
