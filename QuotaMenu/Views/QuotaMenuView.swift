import SwiftUI

struct QuotaMenuView: View {
    @EnvironmentObject var viewModel: QuotaViewModel
    @EnvironmentObject var store: SiteStore
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @State private var initialLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if updateChecker.hasUpdate {
                updateBanner
            }

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

    private var updateBanner: some View {
        HStack(spacing: 0) {
            Button {
                if let url = updateChecker.releaseURL { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 12))
                    Text("新版本 \(updateChecker.latestVersion ?? "") 可用")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                updateChecker.skipCurrentVersion()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("该版本不再提醒")
            .padding(.trailing, 4)
        }
        .background(
            LinearGradient(colors: [.orange, Color(red: 1.0, green: 0.55, blue: 0.0)],
                           startPoint: .leading, endPoint: .trailing)
        )
        .buttonStyle(.plain)
    }
}
