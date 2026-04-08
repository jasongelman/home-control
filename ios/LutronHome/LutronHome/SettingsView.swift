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

    private let oauthContext = OAuthPresentationContext()

    var body: some View {
        Form {
            Section("Processor Connection") {
                TextField("Processor IP Address", text: $host)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("Reconnect") {
                    store.processorHost = host
                    store.connect()
                }
                .tint(.orange)
            }

            Section("Status") {
                HStack {
                    Text("Processor")
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

                HStack {
                    Text("Lights On")
                    Spacer()
                    Text("\(store.lightsOn.count)")
                        .foregroundStyle(.secondary)
                }
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
                        .onChange(of: tcUsername) { _, val in totalConnect.username = val }

                    SecureField("Password", text: $tcPassword)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: tcPassword) { _, val in totalConnect.password = val }

                    SecureField("User Code (PIN)", text: $tcUserCode)
                        .keyboardType(.numberPad)
                        .onChange(of: tcUserCode) { _, val in totalConnect.userCode = val }

                    Button {
                        Task { await totalConnect.login() }
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
        }
    }
}
