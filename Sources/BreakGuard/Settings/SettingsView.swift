import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView(appState: appState)
                .tabItem {
                    Label("Breaks", systemImage: "gearshape")
                }

            WorkingHoursSettingsView(appState: appState)
                .tabItem {
                    Label("Schedule", systemImage: "clock")
                }

            SystemSettingsView(appState: appState)
                .tabItem {
                    Label("App", systemImage: "gearshape.2")
                }

        }
        .frame(minWidth: 540, minHeight: 560)
    }
}
