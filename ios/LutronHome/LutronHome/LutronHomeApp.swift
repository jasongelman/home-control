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
    @State private var totalConnect = TotalConnectManager()
    @Environment(\.scenePhase) private var scenePhase

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
                .environment(totalConnect)
                .preferredColorScheme(.dark)
                .onAppear {
                    store.usageTracker = usageTracker
                    homeKit.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    homeKit.handleScenePhase(active: newPhase == .active)
                    if newPhase == .active {
                        if !store.isConnected { store.connect() }
                        homeConnect.resume()
                        myUplink.resume()
                        smartHQ.resume()
                        myQ.resume()
                        totalConnect.resume()
                    }
                }
        }
    }
}
