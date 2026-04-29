import SwiftUI
import AuthenticationServices

struct SettingsView: View {
    @Environment(LutronStore.self) var store
    @Environment(HomeConnectManager.self) var homeConnect
    @Environment(MyUplinkManager.self) var myUplink
    @Environment(SmartHQManager.self) var smartHQ
    @Environment(MyQManager.self) var myQ
    @Environment(ChatService.self) var chatService
    @Environment(TotalConnectManager.self) var totalConnect
    @Environment(EcobeeManager.self) var ecobee
    @Environment(SonosManager.self) var sonos
    @Environment(SpotifyManager.self) var spotify
    @State private var host: String = ""
    @State private var chatApiKey: String = ""
    @State private var hcClientId: String = ""
    @State private var hcClientSecret: String = ""
    @State private var muClientId: String = ""
    @State private var muClientSecret: String = ""
    @State private var myqEmail: String = ""
    @State private var myqPassword: String = ""
    @State private var tcUsername: String = ""
    @State private var tcPassword: String = ""
    @State private var tcUserCode: String = ""
    @State private var sonosClientId: String = ""
    @State private var sonosClientSecret: String = ""
    @State private var spotifyClientId: String = ""

    private let oauthContext = OAuthPresentationContext()

    var body: some View {
        Form {
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

            // MARK: - Home Connect (Bosch Dishwasher)

            Section {
                HStack {
                    Image(systemName: "dishwasher")
                        .foregroundStyle(.cyan)
                    Text("Bosch Dishwasher")
                        .fontWeight(.medium)
                    Spacer()
                    if homeConnect.isLinked {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if !homeConnect.isLinked {
                    TextField("Client ID", text: $hcClientId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: hcClientId) { _, val in homeConnect.clientId = val }

                    SecureField("Client Secret", text: $hcClientSecret)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: hcClientSecret) { _, val in homeConnect.clientSecret = val }

                    Button {
                        homeConnect.startOAuth(from: oauthContext)
                    } label: {
                        HStack {
                            Image(systemName: "link")
                            Text("Link Home Connect Account")
                        }
                    }
                    .disabled(hcClientId.isEmpty || hcClientSecret.isEmpty)
                } else {
                    if homeConnect.dishwashers.isEmpty {
                        HStack {
                            Text("Appliances")
                            Spacer()
                            Text("Discovering...")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(homeConnect.dishwashers) { dw in
                            HStack {
                                Text(dw.applianceName.isEmpty ? "Dishwasher" : dw.applianceName)
                                Spacer()
                                Text(dw.operationState.label)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        homeConnect.unlink()
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                                .symbolRenderingMode(.multicolor)
                            Text("Unlink Account")
                        }
                    }
                }

                if let error = homeConnect.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Home Connect")
            } footer: {
                Text("Register at developer.home-connect.com to get credentials. Set redirect URI to: com.jasongelman.lutronhome://oauth/homeconnect")
            }

            // MARK: - GE SmartHQ (Washer & Dryer)

            Section {
                HStack {
                    Image(systemName: "washer")
                        .foregroundStyle(.indigo)
                    Text("GE Washer & Dryer")
                        .fontWeight(.medium)
                    Spacer()
                    if smartHQ.isLinked {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if !smartHQ.isLinked {
                    Button {
                        smartHQ.startOAuth(from: oauthContext)
                    } label: {
                        HStack {
                            if smartHQ.isLoading {
                                ProgressView().scaleEffect(0.8)
                            }
                            Image(systemName: "link")
                            Text("Link GE SmartHQ Account")
                        }
                    }
                    .disabled(smartHQ.isLoading)
                    .tint(.indigo)
                } else {
                    if smartHQ.appliances.isEmpty {
                        HStack {
                            Text("Appliances")
                            Spacer()
                            Text("Discovering...")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(smartHQ.appliances) { app in
                            HStack {
                                Image(systemName: app.typeIcon)
                                    .foregroundStyle(app.isWasher ? .indigo : .purple)
                                    .frame(width: 20)
                                Text(app.applianceName)
                                Spacer()
                                Text(app.machineState.label)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        smartHQ.unlink()
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                                .symbolRenderingMode(.multicolor)
                            Text("Sign Out")
                        }
                    }
                }

                if let error = smartHQ.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("GE SmartHQ")
            } footer: {
                Text("Sign in with your GE SmartHQ (Brillion) account. You'll be taken to GE's login page in Safari.")
            }

            // MARK: - myUplink (Dandelion Geothermal)

            Section {
                HStack {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(.green)
                    Text("Dandelion Geothermal")
                        .fontWeight(.medium)
                    Spacer()
                    if myUplink.isLinked {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if !myUplink.isLinked {
                    TextField("Client ID", text: $muClientId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: muClientId) { _, val in myUplink.clientId = val }

                    SecureField("Client Secret", text: $muClientSecret)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: muClientSecret) { _, val in myUplink.clientSecret = val }

                    Button {
                        myUplink.startOAuth(from: oauthContext)
                    } label: {
                        HStack {
                            Image(systemName: "link")
                            Text("Link myUplink Account")
                        }
                    }
                    .disabled(muClientId.isEmpty || muClientSecret.isEmpty)
                } else {
                    HStack {
                        Text("System")
                        Spacer()
                        Text(myUplink.heatPump.systemName.isEmpty ? "Not found" : myUplink.heatPump.systemName)
                            .foregroundStyle(.secondary)
                    }

                    if let mode = myUplink.heatPump.operatingMode {
                        HStack {
                            Text("Mode")
                            Spacer()
                            Text(mode)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        myUplink.unlink()
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                                .symbolRenderingMode(.multicolor)
                            Text("Unlink Account")
                        }
                    }
                }

                if let error = myUplink.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("myUplink")
            } footer: {
                Text("Register at dev.myuplink.com to get credentials. Set redirect URI to: com.jasongelman.lutronhome://oauth/myuplink")
            }

            // MARK: - MyQ (Chamberlain/LiftMaster Garage)

            Section {
                HStack {
                    Image(systemName: "door.garage.closed")
                        .foregroundStyle(.brown)
                    Text("Garage Door Opener")
                        .fontWeight(.medium)
                    Spacer()
                    if myQ.isLinked {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if !myQ.isLinked {
                    TextField("MyQ Email", text: $myqEmail)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .onChange(of: myqEmail) { _, val in myQ.email = val }

                    SecureField("MyQ Password", text: $myqPassword)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: myqPassword) { _, val in myQ.password = val }

                    Button {
                        Task { await myQ.login() }
                    } label: {
                        HStack {
                            if myQ.isLoading {
                                ProgressView().scaleEffect(0.8)
                            }
                            Image(systemName: "link")
                            Text("Sign In")
                        }
                    }
                    .disabled(myqEmail.isEmpty || myqPassword.isEmpty || myQ.isLoading)
                    .tint(.brown)
                } else {
                    if myQ.doors.isEmpty {
                        HStack {
                            Text("Doors")
                            Spacer()
                            Text("Discovering...")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(myQ.doors) { door in
                            HStack {
                                Image(systemName: door.state.icon)
                                    .foregroundStyle(door.state == .open ? .orange : .green)
                                    .frame(width: 20)
                                Text(door.name)
                                Spacer()
                                Text(door.state.label)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        myQ.unlink()
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                                .symbolRenderingMode(.multicolor)
                            Text("Sign Out")
                        }
                    }
                }

                if let error = myQ.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("MyQ")
            } footer: {
                Text("Sign in with your Chamberlain or LiftMaster MyQ account. Requires the MyQ app to be set up first.")
            }

            // MARK: - AI Assistant

            Section {
                HStack {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .foregroundStyle(.orange)
                    Text("Chat Assistant")
                        .fontWeight(.medium)
                    Spacer()
                    if chatService.isConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                SecureField("Anthropic API Key", text: $chatApiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    chatService.apiKey = chatApiKey
                    chatApiKey = ""
                } label: {
                    HStack {
                        Image(systemName: "key.fill")
                        Text("Save Key")
                    }
                }
                .tint(.orange)
                .disabled(chatApiKey.isEmpty)

                if chatService.isConfigured {
                    Button(role: .destructive) {
                        chatService.apiKey = ""
                        chatApiKey = ""
                    } label: {
                        HStack {
                            Image(systemName: "key.slash")
                            Text("Remove Key")
                        }
                    }
                }
            } header: {
                Text("AI Assistant")
            } footer: {
                Text("Enter your Anthropic API key to enable natural language chat control. The key is stored securely in the Keychain. Get a key at console.anthropic.com.")
            }

            // MARK: - Ecobee Thermostat (HomeKit)

            Section {
                HStack {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(.green)
                    Text("Thermostats")
                        .fontWeight(.medium)
                    Spacer()
                    if ecobee.hasThermostats {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if ecobee.thermostats.isEmpty {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text("Waiting for HomeKit...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(ecobee.thermostats) { thermo in
                        HStack {
                            Image(systemName: thermo.hvacMode.icon)
                                .foregroundStyle(.green)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("Name", text: Binding(
                                    get: { thermo.displayName },
                                    set: { ecobee.setNameOverride(for: thermo.identifier, name: $0) }
                                ))
                                if EcobeeManager.nameOverride(for: thermo.identifier) != nil && thermo.name != thermo.displayName {
                                    Text(thermo.name)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(Int(thermo.currentTemp))\u{00B0}F")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = ecobee.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Climate")
            } footer: {
                Text("Thermostats are discovered automatically via HomeKit. Tap a name to rename it.")
            }

            // MARK: - Sonos

            Section {
                HStack {
                    Image(systemName: "hifispeaker.2.fill")
                        .foregroundStyle(.orange)
                    Text("Sonos Speakers")
                        .fontWeight(.medium)
                    Spacer()
                    if sonos.hasPlayers {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if sonos.players.isEmpty {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text("Discovering...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(sonos.players) { player in
                        HStack {
                            Image(systemName: "hifispeaker.fill")
                                .foregroundStyle(.orange)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(player.name)
                                Text("\(player.modelName) · \(player.ipAddress)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if player.state == .playing {
                                Image(systemName: "waveform")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .symbolEffect(.variableColor.iterative)
                            }
                        }
                    }
                }

                // Cloud linking
                if !sonos.isCloudLinked {
                    TextField("Sonos Client ID", text: $sonosClientId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: sonosClientId) { _, val in
                            sonos.setClientCredentials(clientId: val, clientSecret: sonosClientSecret)
                        }

                    SecureField("Client Secret", text: $sonosClientSecret)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: sonosClientSecret) { _, val in
                            sonos.setClientCredentials(clientId: sonosClientId, clientSecret: val)
                        }

                    Button {
                        sonos.startOAuth(from: oauthContext)
                    } label: {
                        HStack {
                            Image(systemName: "link")
                            Text("Link Sonos Account")
                        }
                    }
                    .disabled(sonosClientId.isEmpty || sonosClientSecret.isEmpty)
                    .tint(.orange)
                } else {
                    HStack {
                        Text("Cloud API")
                        Spacer()
                        Text("Connected")
                            .foregroundStyle(.green)
                    }

                    Button(role: .destructive) {
                        sonos.unlinkCloud()
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                                .symbolRenderingMode(.multicolor)
                            Text("Unlink Account")
                        }
                    }
                }

                if let error = sonos.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Sonos")
            } footer: {
                Text("Speakers are discovered automatically on your local network. Cloud linking is optional — enables browsing favorites and playlists. Register at developer.sonos.com for credentials.")
            }

            // MARK: - Spotify

            Section {
                HStack {
                    Image(systemName: "waveform")
                        .foregroundStyle(.green)
                    Text("Spotify")
                        .fontWeight(.medium)
                    Spacer()
                    if spotify.isLinked {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if !spotify.isLinked {
                    TextField("Spotify Client ID", text: $spotifyClientId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: spotifyClientId) { _, val in
                            spotify.setClientId(val)
                        }

                    Button {
                        Task {
                            do {
                                try await spotify.startOAuth(from: oauthContext)
                            } catch {
                                print("Spotify OAuth error: \(error)")
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "link")
                            Text("Link Spotify")
                        }
                    }
                    .disabled(spotifyClientId.isEmpty)
                    .tint(.green)
                } else {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text("Connected")
                            .foregroundStyle(.green)
                    }

                    Button(role: .destructive) {
                        spotify.unlink()
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                                .symbolRenderingMode(.multicolor)
                            Text("Unlink Spotify")
                        }
                    }
                }
            } header: {
                Text("Spotify")
            } footer: {
                Text("Search and play Spotify content on your Sonos speakers. Requires a Spotify Client ID from developer.spotify.com — create an app, add \(Text("lutronhome://oauth/spotify").bold()) as a redirect URI.")
            }

            // MARK: - Resideo / Total Connect 2.0

            Section {
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.red)
                    Text("Resideo Alarm")
                        .fontWeight(.medium)
                    Spacer()
                    if totalConnect.isLinked {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if !totalConnect.isLinked {
                    TextField("Total Connect Username", text: $tcUsername)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("Password", text: $tcPassword)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("User Code (PIN)", text: $tcUserCode)
                        .keyboardType(.numberPad)

                    Button {
                        // Submit credentials in a single shot. The local
                        // @State strings are zeroed immediately afterwards so
                        // they don't outlive the call in memory; the canonical
                        // copy lives in Keychain (managed by
                        // TotalConnectManager).
                        let user = tcUsername
                        let pass = tcPassword
                        let pin  = tcUserCode
                        Task {
                            await totalConnect.signIn(username: user, password: pass, userCode: pin)
                            await MainActor.run {
                                tcUsername = ""
                                tcPassword = ""
                                tcUserCode = ""
                            }
                        }
                    } label: {
                        HStack {
                            if totalConnect.isLoading {
                                ProgressView().scaleEffect(0.8)
                            }
                            Image(systemName: "link")
                            Text("Sign In")
                        }
                    }
                    .disabled(tcUsername.isEmpty || tcPassword.isEmpty || totalConnect.isLoading)
                    .tint(.red)
                } else {
                    if totalConnect.panels.isEmpty {
                        HStack {
                            Text("Panels")
                            Spacer()
                            Text("Discovering...")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(totalConnect.panels) { panel in
                            HStack {
                                Image(systemName: panel.state.icon)
                                    .foregroundStyle(panel.state == .alarming ? .red : panel.state.isArmed ? .orange : .green)
                                    .frame(width: 20)
                                Text(panel.name)
                                Spacer()
                                Text(panel.state.label)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        totalConnect.unlink()
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                                .symbolRenderingMode(.multicolor)
                            Text("Sign Out")
                        }
                    }
                }

                if let error = totalConnect.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Resideo")
            } footer: {
                Text("Sign in with your Total Connect 2.0 account credentials (same as the T.C. 2.0 app). Your user code is the PIN used to arm/disarm your panel.")
            }

            // MARK: - For You Insights

            Section {
                NavigationLink(destination: PersonalizationInsightsView()) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.orange)
                        Text("For You Insights")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(store.usageTracker?.events.count ?? 0) events")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Personalization")
            } footer: {
                Text("See the data and patterns behind your For You suggestions.")
            }

            Section("About") {
                HStack {
                    Text("Connection")
                    Spacer()
                    Text("Direct LEAP (no server)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                HStack {
                    Text("Port")
                    Spacer()
                    Text("8081 (TLS + mTLS)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            host = store.processorHost
            hcClientId = homeConnect.clientId
            hcClientSecret = homeConnect.clientSecret
            muClientId = myUplink.clientId
            muClientSecret = myUplink.clientSecret
            myqEmail = myQ.email
            myqPassword = myQ.password
            sonosClientId = KeychainHelper.loadString(for: "sonos-clientId") ?? ""
            sonosClientSecret = KeychainHelper.loadString(for: "sonos-clientSecret") ?? ""
            spotifyClientId = UserDefaults.standard.string(forKey: "spotify_client_id") ?? ""
        }
    }
}
