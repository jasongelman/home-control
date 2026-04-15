import SwiftUI

struct RoomDetailView: View {
    @Environment(LutronStore.self) var store
    @Environment(EcobeeManager.self) var ecobee
    @Environment(SonosManager.self) var sonos
    let roomName: String
    let onBack: () -> Void

    private var devices: [DeviceState] {
        store.devices.values.filter { $0.room == roomName }.sorted { $0.name < $1.name }
    }
    private var lights: [DeviceState] { devices.filter { $0.category == .light } }
    private var shades: [DeviceState] { devices.filter { $0.category == .shadesAndDrapes } }
    private var outlets: [DeviceState] { devices.filter { $0.category == .outlet } }
    private var fans: [DeviceState] { devices.filter { $0.category == .fan } }
    private var windows: [DeviceState] { devices.filter { $0.category == .window } }
    private var keypads: [DeviceState] { devices.filter { $0.type == .keypad } }

    private var roomThermostats: [EcobeeThermostat] {
        ecobee.thermostats.filter { $0.room == roomName }
    }
    private var roomSensors: [EcobeeRemoteSensor] {
        ecobee.sensors.filter { $0.room == roomName }
    }
    private var roomSonosPlayer: SonosPlayer? {
        sonos.player(forRoom: roomName)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Climate sensors/thermostats for this room
                if !roomThermostats.isEmpty || !roomSensors.isEmpty {
                    DeviceSection(title: "Climate", icon: "thermometer.medium", count: roomThermostats.count + roomSensors.count) {
                        VStack(spacing: 8) {
                            ForEach(roomThermostats) { thermo in
                                HStack(spacing: 10) {
                                    Image(systemName: thermo.hvacMode.icon)
                                        .font(.system(size: 14))
                                        .foregroundStyle(.green)
                                        .frame(width: 22)
                                    Text(thermo.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Text("\(Int(thermo.currentTemp))\u{00B0}F")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text(thermo.hvacMode.label)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
                                )
                            }
                            ForEach(roomSensors) { sensor in
                                HStack(spacing: 10) {
                                    Image(systemName: sensor.occupancy ? "person.fill" : "thermometer")
                                        .font(.system(size: 14))
                                        .foregroundStyle(sensor.occupancy ? .green : .secondary)
                                        .frame(width: 22)
                                    Text(sensor.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    if let temp = sensor.temp {
                                        Text("\(Int(temp))\u{00B0}F")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    if sensor.occupancy {
                                        Text("Occupied")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(12)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
                                )
                            }
                        }
                    }
                }

                // Sonos speaker for this room
                if let player = roomSonosPlayer {
                    DeviceSection(title: "Music", icon: "hifispeaker.fill", count: 1) {
                        HStack(spacing: 12) {
                            Image(systemName: player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.orange)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(player.name)
                                    .font(.system(size: 13, weight: .medium))
                                if let track = player.currentTrack {
                                    Text("\(track.title) · \(track.artist)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("Not Playing")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button {
                                Task {
                                    if player.state == .playing {
                                        try? await sonos.pausePlayback(playerId: player.id)
                                    } else {
                                        try? await sonos.play(playerId: player.id)
                                    }
                                }
                            } label: {
                                Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
                        )
                    }
                }

                if !lights.isEmpty {
                    DeviceSection(title: "Lights", icon: "lightbulb.fill", count: lights.count) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(lights) { device in
                                LightControlCard(device: device)
                            }
                        }
                    }
                }

                if !shades.isEmpty {
                    DeviceSection(title: "Shades", icon: "blinds.vertical.open", count: shades.count) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(shades) { device in
                                ShadeControlCard(device: device)
                            }
                        }
                    }
                }

                if !keypads.isEmpty {
                    DeviceSection(title: "Scenes", icon: "keyboard", count: keypads.count) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(keypads) { device in
                                KeypadCard(device: device)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(roomName)
        .navigationBarTitleDisplayMode(.large)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - Section Header

struct DeviceSection<Content: View>: View {
    let title: String
    let icon: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemGray5))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
                Rectangle()
                    .fill(Color(.separator).opacity(0.3))
                    .frame(height: 0.5)
            }
            content
        }
    }
}

// MARK: - Light Control

struct LightControlCard: View {
    @Environment(LutronStore.self) var store
    let device: DeviceState
    @State private var localLevel: Double

    init(device: DeviceState) {
        self.device = device
        _localLevel = State(initialValue: device.level)
    }

    var isOn: Bool { localLevel > 0 }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    let newLevel: Double = device.level > 0 ? 0 : 100
                    localLevel = newLevel
                    store.setLevel(device.integrationId, level: newLevel, fadeTime: 1)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isOn ? .orange : Color(.systemGray3))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .stroke(isOn ? Color.orange.opacity(0.4) : Color(.separator).opacity(0.4), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)

                Text(device.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(Int(localLevel))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $localLevel, in: 0...100, step: 1) { editing in
                if !editing {
                    store.setLevel(device.integrationId, level: localLevel)
                }
            }
            .tint(isOn ? .orange : .secondary)
        }
        .padding(12)
        .background(lightCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isOn ? Color.orange.opacity(0.2) : Color(.separator).opacity(0.4), lineWidth: 0.5)
        )
        .onChange(of: device.level) { _, newValue in
            localLevel = newValue
        }
    }

    @ViewBuilder
    private var lightCardBackground: some View {
        if isOn {
            LinearGradient(
                colors: [Color.orange.opacity(0.08), Color(.secondarySystemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color(.secondarySystemBackground)
        }
    }
}

// MARK: - Shade Control

struct ShadeControlCard: View {
    @Environment(LutronStore.self) var store
    let device: DeviceState
    @State private var localLevel: Double

    init(device: DeviceState) {
        self.device = device
        _localLevel = State(initialValue: device.level)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "blinds.vertical.open")
                    .font(.system(size: 14))
                    .foregroundStyle(.teal)

                Text(device.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(Int(localLevel))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $localLevel, in: 0...100, step: 1) { editing in
                if !editing {
                    store.setLevel(device.integrationId, level: localLevel, fadeTime: 2)
                }
            }
            .tint(.teal)

            HStack(spacing: 4) {
                ForEach([0, 25, 50, 75, 100], id: \.self) { preset in
                    Button {
                        localLevel = Double(preset)
                        store.setLevel(device.integrationId, level: Double(preset), fadeTime: 2)
                    } label: {
                        Text(preset == 0 ? "Close" : preset == 100 ? "Open" : "\(preset)%")
                            .font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                Int(localLevel) == preset
                                    ? Color.teal
                                    : Color(.tertiarySystemBackground)
                            )
                            .foregroundStyle(Int(localLevel) == preset ? .white : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
        )
        .onChange(of: device.level) { _, newValue in
            localLevel = newValue
        }
    }
}

// MARK: - Keypad

struct KeypadCard: View {
    let device: DeviceState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text(device.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            if let components = device.components, !components.isEmpty {
                ForEach(components) { comp in
                    Button(comp.name) {
                        // TODO: press/release
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Text("No buttons")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
        )
    }
}
