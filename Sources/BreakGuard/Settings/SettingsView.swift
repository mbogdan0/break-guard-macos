import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView(appState: appState)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            WorkingHoursSettingsView(appState: appState)
                .tabItem {
                    Label("Schedule", systemImage: "clock")
                }

            SystemSettingsView(appState: appState)
                .tabItem {
                    Label("System", systemImage: "gearshape.2")
                }

            StatisticsSettingsView(appState: appState)
                .tabItem {
                    Label("Statistics", systemImage: "chart.bar")
                }

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 540, minHeight: 560)
    }
}
