import SwiftUI

struct QuotaMenuView: View {
    @EnvironmentObject var viewModel: QuotaViewModel
    @EnvironmentObject var store: SiteStore
    @State private var initialLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.sites.isEmpty {
                emptyState
            } else if let error = viewModel.errorMessage, viewModel.quotas.isEmpty {
                errorState(error)
            } else {
                QuotaListView()
                    .environmentObject(viewModel)
            }

            Divider()
            footer
        }
        .frame(width: 400)
        .onAppear {
            if !initialLoaded && !store.sites.isEmpty {
                initialLoaded = true
                Task { await viewModel.refresh() }
            }
        }
    }

    private var header: some View {
        HStack {
            if store.sites.count > 1 {
                Menu {
                    ForEach(store.sites) { site in
                        Button {
                            store.currentSiteID = site.id
                            viewModel.onSiteChanged()
                        } label: {
                            HStack {
                                Text(site.name)
                                if site.id == store.currentSite?.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.currentSite?.name ?? "No Site").font(.headline)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }
                .menuStyle(.button)
            } else {
                Text(store.currentSite?.name ?? "QuotaMenu").font(.headline)
            }

            Spacer()

            if viewModel.isLoading {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
            }

            Button { Task { await viewModel.fullRefresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("No sites configured").font(.subheadline).foregroundStyle(.secondary)
            Button("Add Site") {
                WindowManager.shared.open(id: "add-site", title: "Add Site", width: 360, height: 220) {
                    SiteEditorView(store: store, onDismiss: {
                        WindowManager.shared.close(id: "add-site")
                        Task { await viewModel.refresh() }
                    })
                }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding()
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry") { Task { await viewModel.refresh() } }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
    }

    private var footer: some View {
        HStack {
            if let date = viewModel.lastRefresh {
                Text(timeAgo(date)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                WindowManager.shared.open(id: "settings", title: "QuotaMenu Settings", width: 450, height: 350) {
                    SettingsView().environmentObject(store).environmentObject(viewModel)
                }
            } label: { Image(systemName: "gearshape") }
            .buttonStyle(.borderless)

            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func timeAgo(_ date: Date) -> String {
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 10 { return "Just now" }
        if diff < 60 { return "\(diff)s ago" }
        let m = diff / 60
        if m < 60 { return "\(m)m ago" }
        return "\(m / 60)h ago"
    }
}
