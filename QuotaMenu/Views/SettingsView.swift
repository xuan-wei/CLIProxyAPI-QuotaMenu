import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var viewModel: QuotaViewModel
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            SitesSettingsView()
                .environmentObject(store)
                .environmentObject(viewModel)
                .tabItem { Label("Sites", systemImage: "globe") }
                .tag(0)

            NotificationSettingsView()
                .environmentObject(viewModel)
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(1)

            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(2)
        }
        .frame(width: 450, height: 350)
    }
}

struct SitesSettingsView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var viewModel: QuotaViewModel
    @State private var editingSite: Site?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(selection: Binding(
                get: { store.currentSiteID },
                set: { id in
                    store.currentSiteID = id
                    viewModel.onSiteChanged()
                }
            )) {
                ForEach(store.sites) { site in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(site.name).fontWeight(.medium)
                            Text(site.url).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if site.id == store.currentSite?.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                        }
                    }
                    .tag(site.id)
                    .contextMenu {
                        Button("Edit") { editingSite = site }
                        Button("Delete", role: .destructive) { store.removeSite(site) }
                    }
                }
            }
            .listStyle(.bordered)

            HStack {
                Button("Add Site") { isAdding = true }
                Spacer()
                if let site = store.currentSite {
                    Button("Edit Current") { editingSite = site }
                }
            }
        }
        .padding()
        .sheet(isPresented: $isAdding) {
            SiteEditorView(store: store) { isAdding = false }
        }
        .sheet(item: $editingSite) { site in
            SiteEditorView(store: store, site: site) { editingSite = nil }
        }
    }
}

struct SiteEditorView: View {
    @ObservedObject var store: SiteStore
    var site: Site?
    var onDismiss: () -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var managementKey = ""

    var isEditing: Bool { site != nil }

    var body: some View {
        VStack(spacing: 16) {
            Text(isEditing ? "Edit Site" : "Add Site").font(.headline)

            Form {
                TextField("Name", text: $name, prompt: Text("My CLIProxyAPI"))
                TextField("URL", text: $url, prompt: Text("https://cliproxyapi.example.com"))
                SecureField("Management Key", text: $managementKey, prompt: Text("Required"))
            }

            HStack {
                Button("Cancel") { onDismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "Save" : "Add") { save(); onDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || url.isEmpty || managementKey.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let site {
                name = site.name
                url = site.url
                managementKey = store.managementKey(for: site)
            }
        }
    }

    private func save() {
        if var existing = site {
            existing.name = name
            existing.url = url
            store.updateSite(existing)
            store.setManagementKey(managementKey, for: existing)
        } else {
            let newSite = Site(name: name, url: url)
            store.addSite(newSite)
            store.setManagementKey(managementKey, for: newSite)
        }
    }
}

struct NotificationSettingsView: View {
    @EnvironmentObject var viewModel: QuotaViewModel
    private let intervals = [(5, "5 min"), (15, "15 min"), (30, "30 min"), (60, "1 hour"), (120, "2 hours")]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Refresh Interval")
                Spacer()
                Picker("", selection: $viewModel.refreshInterval) {
                    ForEach(intervals, id: \.0) { value, label in Text(label).tag(value) }
                }
                .frame(width: 120)
                .onChange(of: viewModel.refreshInterval) { viewModel.startTimer() }
            }

            Divider()

            Toggle("Enable Alert Notifications", isOn: $viewModel.alertEnabled)
            if viewModel.alertEnabled {
                HStack {
                    Text("Alert Threshold")
                    Spacer()
                    TextField("", value: $viewModel.alertThreshold, format: .number)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                    Text("%")
                }
                Text("Alert when remaining quota falls below this value")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }
}

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch { launchAtLogin = !newValue }
                }

            Divider()

            HStack {
                Text("Version"); Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Quit QuotaMenu") { NSApplication.shared.terminate(nil) }
        }
        .padding()
    }
}
