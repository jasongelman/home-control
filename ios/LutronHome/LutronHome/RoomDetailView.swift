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
            VStack(alignment: .leading, spacing: EditorialTheme.sectionSpacing) {
                // Header with back button
                HStack(alignment: .firstTextBaseline) {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("BACK")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.8)
                        }
                        .foregroundStyle(EditorialTheme.accent)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                Text(roomName.uppercased())
                    .font(EditorialTheme.bebasNeue(size: 32))
                    .foregroundStyle(EditorialTheme.primaryText)

                // Climate sensors/thermostats for this room
                if !roomThermostats.isEmpty || !roomSensors.isEmpty {
                    VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                        EditorialSectionHeader(title: "Climate", trailing: "\(roomThermostats.count + roomSensors.count)")
                        VStack(spacing: 6) {
                            ForEach(roomThermostats) { thermo in
                                HStack(spacing: 10) {
                                    Image(systemName: thermo.hvacMode.icon)
                                        .font(.system(size: 12))
                                        .foregroundStyle(EditorialTheme.accent)
                                        .frame(width: 20)
                                    Text(thermo.displayName.uppercased())
                                        .font(.system(size: 10, weight: .semibold))
                                        .tracking(0.6)
                                        .foregroundStyle(EditorialTheme.primaryText)
                                    Spacer()
                                    Text("\(Int(thermo.currentTemp))\u{00B0}F")
                                        .font(EditorialTheme.monoValue(size: 14))
                                        .foregroundStyle(EditorialTheme.accent)
                                    Text(thermo.hvacMode.label.uppercased())
                                        .font(.system(size: 9, weight: .medium))
                                        .tracking(0.4)
                                        .foregroundStyle(EditorialTheme.secondaryText)
                                }
                                .editorialCard(padding: 10)
                            }
                            ForEach(roomSensors) { sensor in
                                HStack(spacing: 10) {
                                    Image(systemName: sensor.occupancy ? "person.fill" : "thermometer")
                                        .font(.system(size: 12))
                                        .foregroundStyle(sensor.occupancy ? EditorialTheme.accent : EditorialTheme.secondaryText)
                                        .frame(width: 20)
                                    Text(sensor.name.uppercased())
                                        .font(.system(size: 10, weight: .semibold))
                                        .tracking(0.6)
                                        .foregroundStyle(EditorialTheme.primaryText)
                                    Spacer()
                                    if let temp = sensor.temp {
                                        Text("\(Int(temp))\u{00B0}F")
                                            .font(EditorialTheme.monoValue(size: 14))
                                            .foregroundStyle(EditorialTheme.accent)
                                    }
                                    if sensor.occupancy {
                                        Text("OCCUPIED")
                                            .font(.system(size: 9, weight: .medium))
                                            .tracking(0.4)
                                            .foregroundStyle(EditorialTheme.accent)
                                    }
                                }
                                .editorialCard(padding: 10)
                            }
                        }
                    }
                }

                // Sonos speaker for this room
                if let player = roomSonosPlayer {
                    VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                        EditorialSectionHeader(title: "Music")
                        HStack(spacing: 12) {
                            Image(systemName: player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(EditorialTheme.accent)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(player.name.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(0.6)
                                    .foregroundStyle(EditorialTheme.primaryText)
                                if let track = player.currentTrack {
                                    Text("\(track.title) · \(track.artist)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(EditorialTheme.secondaryText)
                                        .lineLimit(1)
                                } else {
                                    Text("NOT PLAYING")
                                        .font(.system(size: 9, weight: .medium))
                                        .tracking(0.4)
                                        .foregroundStyle(EditorialTheme.secondaryText)
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
                                    .font(.system(size: 22))
                                    .foregroundStyle(EditorialTheme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        .editorialCard(padding: 10)
                    }
                }

                if !lights.isEmpty {
                    VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                        EditorialSectionHeader(title: "Lights", trailing: "\(lights.count)")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: EditorialTheme.gridSpacing) {
                            ForEach(lights) { device in
                                LightControlCard(device: device)
                            }
                        }
                    }
                }

                if !shades.isEmpty {
                    VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                        EditorialSectionHeader(title: "Shades", trailing: "\(shades.count)")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: EditorialTheme.gridSpacing) {
                            ForEach(shades) { device in
                                ShadeControlCard(device: device)
                            }
                        }
                    }
                }

                if !keypads.isEmpty {
                    VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                        EditorialSectionHeader(title: "Scenes", trailing: "\(keypads.count)")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: EditorialTheme.gridSpacing) {
                            ForEach(keypads) { device in
                                KeypadCard(device: device)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
        }
        .background(EditorialTheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - Section Header

struct DeviceSection<Content: View>: View {
    let title: String
    let icon: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
            EditorialSectionHeader(title: title, trailing: "\(count)")
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
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isOn ? EditorialTheme.accent : EditorialTheme.secondaryText)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .stroke(isOn ? EditorialTheme.accent.opacity(0.4) : EditorialTheme.cardBorder, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)

                Text(device.name.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(EditorialTheme.primaryText)

                Text("\(Int(localLevel))%")
                    .font(EditorialTheme.monoValue(size: 11))
                    .foregroundStyle(isOn ? EditorialTheme.accent : EditorialTheme.secondaryText)
            }

            Slider(value: $localLevel, in: 0...100, step: 1) { editing in
                if !editing {
                    store.setLevel(device.integrationId, level: localLevel)
                }
            }
            .tint(isOn ? EditorialTheme.accent : EditorialTheme.secondaryText)
        }
        .padding(10)
        .background(EditorialTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                .stroke(isOn ? EditorialTheme.accent.opacity(0.3) : EditorialTheme.cardBorder, lineWidth: 0.5)
        )
        .onChange(of: device.level) { _, newValue in
            localLevel = newValue
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
                    .font(.system(size: 12))
                    .foregroundStyle(EditorialTheme.accent)

                Text(device.name.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(EditorialTheme.primaryText)

                Text("\(Int(localLevel))%")
                    .font(EditorialTheme.monoValue(size: 11))
                    .foregroundStyle(EditorialTheme.accent)
            }

            Slider(value: $localLevel, in: 0...100, step: 1) { editing in
                if !editing {
                    store.setLevel(device.integrationId, level: localLevel, fadeTime: 2)
                }
            }
            .tint(EditorialTheme.accent)

            HStack(spacing: 4) {
                ForEach([0, 25, 50, 75, 100], id: \.self) { preset in
                    Button {
                        localLevel = Double(preset)
                        store.setLevel(device.integrationId, level: Double(preset), fadeTime: 2)
                    } label: {
                        Text(preset == 0 ? "CLOSE" : preset == 100 ? "OPEN" : "\(preset)%")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                Int(localLevel) == preset
                                    ? EditorialTheme.accent
                                    : EditorialTheme.cardBackground
                            )
                            .foregroundStyle(Int(localLevel) == preset ? .white : EditorialTheme.secondaryText)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(EditorialTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
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
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 10))
                    .foregroundStyle(EditorialTheme.secondaryText)
                Text(device.name.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .lineLimit(1)
                    .foregroundStyle(EditorialTheme.primaryText)
            }
            if let components = device.components, !components.isEmpty {
                ForEach(components) { comp in
                    Button(comp.name.uppercased()) {
                        // TODO: press/release
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(EditorialTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
                    )
                }
            } else {
                Text("NO BUTTONS")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(EditorialTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(EditorialTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
        )
    }
}
