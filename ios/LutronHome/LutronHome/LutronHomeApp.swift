import SwiftUI

@main
struct LutronHomeApp: App {
    @State private var store = LutronStore()
    @State private var usageTracker = UsageTracker()
    @State private var homeKit = HomeKitManager()
    @State private var homeConnect = HomeConnectManager()
    @State private var myUplink = MyUplinkManager()
    @State private var smartHQ = SmartHQManager()
    @State private var myQ = MyQManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showVoiceInput = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(usageTracker)
                .environment(homeKit)
                .environment(homeConnect)
                .environment(myUplink)
                .environment(smartHQ)
                .environment(myQ)
                .preferredColorScheme(.dark)
                .onAppear {
                    store.usageTracker = usageTracker
                    homeKit.start()
                    // Register Siri shortcuts
                    LutronShortcutsProvider.updateAppShortcutParameters()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    homeKit.handleScenePhase(active: newPhase == .active)
                    if newPhase == .active {
                        if !store.isConnected { store.connect() }
                        homeConnect.resume()
                        myUplink.resume()
                        smartHQ.resume()
                        myQ.resume()
                        // Sync appliance status to widget
                        syncApplianceStatus()
                    }
                }
                .onOpenURL { url in
                    if url.host == "voice" {
                        showVoiceInput = true
                    }
                }
                .sheet(isPresented: $showVoiceInput) {
                    NavigationStack {
                        ChatView(autoStartVoice: true)
                            .environment(store)
                            .navigationTitle("Voice Command")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { showVoiceInput = false }
                                }
                            }
                    }
                }
        }
    }

    private func syncApplianceStatus() {
        var appliances: [AppGroupManager.ApplianceInfo] = []

        for dw in homeConnect.dishwashers where dw.operationState == .run {
            if let seconds = dw.remainingTime, seconds > 0 {
                appliances.append(.init(name: "Dishwasher", remainingMinutes: seconds / 60))
            }
        }
        for app in smartHQ.appliances where app.machineState == .running {
            if let minutes = app.remainingMinutes, minutes > 0 {
                let name = app.type == .washer ? "Washer" : "Dryer"
                appliances.append(.init(name: name, remainingMinutes: minutes))
            }
        }

        AppGroupManager.writeApplianceStatus(appliances)
        AppGroupManager.reloadWidgets()
    }
}
