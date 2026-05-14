import Foundation
import SwiftUI
import Combine

@MainActor
final class QuotaViewModel: ObservableObject {
    @Published var quotas: [QuotaItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastRefresh: Date?
    @Published var accountOrder: [String] = []
    @Published var hiddenAccounts: Set<String> = []
    @Published var showHidden: Bool = false

    @AppStorage("refreshInterval") var refreshInterval: Int = 30
    @AppStorage("alertEnabled") var alertEnabled: Bool = true
    @AppStorage("alertThreshold") var alertThreshold: Int = 20

    private let store: SiteStore
    private let fetcher = QuotaFetcher()
    private var timer: AnyCancellable?
    private var alerted: Set<String> = []

    init(store: SiteStore = .shared) {
        self.store = store
        if let data = UserDefaults.standard.data(forKey: "accountOrder"),
           let order = try? JSONDecoder().decode([String].self, from: data) {
            self.accountOrder = order
        }
        if let data = UserDefaults.standard.data(forKey: "hiddenAccounts"),
           let hidden = try? JSONDecoder().decode(Set<String>.self, from: data) {
            self.hiddenAccounts = hidden
        }
        startTimer()
    }

    var groupedQuotas: [(provider: String, label: String, items: [QuotaItem])] {
        let sorted = sortedQuotas
        var groups: [(provider: String, label: String, items: [QuotaItem])] = []
        var seen: Set<String> = []

        for p in QuotaItem.providerOrder {
            let items = sorted.filter { $0.provider == p }
            if !items.isEmpty {
                groups.append((p, QuotaItem.providerLabels[p] ?? p, items))
                seen.insert(p)
            }
        }
        let rest = sorted.filter { !seen.contains($0.provider) }
        if !rest.isEmpty {
            let p = rest.first!.provider
            groups.append((p, QuotaItem.providerLabels[p] ?? p, rest))
        }
        return groups
    }

    private var sortedQuotas: [QuotaItem] {
        if accountOrder.isEmpty { return quotas }
        return quotas.sorted { a, b in
            let ai = accountOrder.firstIndex(of: a.id) ?? Int.max
            let bi = accountOrder.firstIndex(of: b.id) ?? Int.max
            return ai < bi
        }
    }

    func saveOrder() {
        accountOrder = sortedQuotas.map { $0.id }
        if let data = try? JSONEncoder().encode(accountOrder) {
            UserDefaults.standard.set(data, forKey: "accountOrder")
        }
    }

    func toggleHidden(_ accountId: String) {
        if hiddenAccounts.contains(accountId) {
            hiddenAccounts.remove(accountId)
        } else {
            hiddenAccounts.insert(accountId)
        }
        saveHidden()
    }

    func toggleProviderHidden(_ provider: String) {
        let items = quotas.filter { $0.provider == provider }
        let allHidden = items.allSatisfy { hiddenAccounts.contains($0.id) }
        if allHidden {
            for item in items { hiddenAccounts.remove(item.id) }
        } else {
            for item in items { hiddenAccounts.insert(item.id) }
        }
        saveHidden()
    }

    func isHidden(_ accountId: String) -> Bool { hiddenAccounts.contains(accountId) }

    private func saveHidden() {
        if let data = try? JSONEncoder().encode(hiddenAccounts) {
            UserDefaults.standard.set(data, forKey: "hiddenAccounts")
        }
    }

    func moveItems(provider: String, from source: IndexSet, to destination: Int) {
        var items = groupedQuotas.first(where: { $0.provider == provider })?.items ?? []
        items.move(fromOffsets: source, toOffset: destination)
        let movedIds = items.map { $0.id }

        var newOrder = accountOrder.filter { id in !movedIds.contains(id) }
        let insertAt = newOrder.firstIndex(where: { id in
            guard let q = quotas.first(where: { $0.id == id }) else { return false }
            return q.provider == provider
        }) ?? newOrder.endIndex

        for (i, id) in movedIds.enumerated() {
            newOrder.insert(id, at: min(insertAt + i, newOrder.endIndex))
        }
        accountOrder = newOrder
        saveOrder()
        objectWillChange.send()
    }

    func refresh() async {
        guard let site = store.currentSite else {
            errorMessage = "No site configured"
            quotas = []
            return
        }

        isLoading = true
        errorMessage = nil

        let key = store.managementKey(for: site)
        let items = await fetcher.fetchAll(site: site, key: key)

        if items.isEmpty && quotas.isEmpty {
            errorMessage = "No quota data returned"
        } else {
            quotas = items
            lastRefresh = Date()
            if alertEnabled { checkAlerts(items) }
        }

        // Initialize order for new items
        let existingIds = Set(accountOrder)
        for item in items where !existingIds.contains(item.id) {
            accountOrder.append(item.id)
        }

        isLoading = false
    }

    func refreshAccount(_ accountName: String) async {
        guard let site = store.currentSite else { return }
        let key = store.managementKey(for: site)
        let items = await fetcher.refreshAccount(site: site, key: key, accountName: accountName)
        quotas = items
        lastRefresh = Date()
    }

    func fullRefresh() async {
        guard let site = store.currentSite else { return }
        isLoading = true
        errorMessage = nil
        let key = store.managementKey(for: site)
        let items = await fetcher.refreshAll(site: site, key: key)
        quotas = items
        lastRefresh = Date()
        if alertEnabled { checkAlerts(items) }
        isLoading = false
    }

    func startTimer() {
        timer?.cancel()
        let interval = TimeInterval(refreshInterval * 60)
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.refresh() }
            }
    }

    func onSiteChanged() {
        alerted.removeAll()
        quotas = []
        errorMessage = nil
        Task { await refresh() }
    }

    private func checkAlerts(_ items: [QuotaItem]) {
        let threshold = Double(alertThreshold)
        for item in items where !item.isError {
            for window in item.windows {
                guard let remaining = window.remainingPercent, remaining < threshold else { continue }
                let key = "\(item.provider):\(item.account):\(window.label)"
                guard !alerted.contains(key) else { continue }
                alerted.insert(key)
                NotificationService.send(
                    title: "[\(item.displayProvider)] \(item.displayAccount)",
                    body: "\(window.label) remaining \(String(format: "%.1f", remaining))%",
                    identifier: key
                )
            }
        }
    }
}
