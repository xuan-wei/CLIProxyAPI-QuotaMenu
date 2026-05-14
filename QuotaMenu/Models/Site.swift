import Foundation

struct Site: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var url: String

    init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name
        self.url = Self.normalizeURL(url)
    }

    private var baseURL: String { Self.normalizeURL(url) }

    var authFilesURL: URL? { URL(string: "\(baseURL)/v0/management/auth-files") }
    var apiCallURL: URL? { URL(string: "\(baseURL)/v0/management/api-call") }
    func downloadURL(name: String) -> URL? {
        var comp = URLComponents(string: "\(baseURL)/v0/management/auth-files/download")
        comp?.queryItems = [URLQueryItem(name: "name", value: name)]
        return comp?.url
    }

    private static func normalizeURL(_ raw: String) -> String {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.hasPrefix("http") { u = "https://\(u)" }
        while u.hasSuffix("/") { u = String(u.dropLast()) }
        return u
    }
}

final class SiteStore: ObservableObject {
    static let shared = SiteStore()

    @Published var sites: [Site] { didSet { save() } }
    @Published var currentSiteID: UUID? {
        didSet { UserDefaults.standard.set(currentSiteID?.uuidString, forKey: "currentSiteID") }
    }

    var currentSite: Site? {
        guard let id = currentSiteID else { return sites.first }
        return sites.first { $0.id == id } ?? sites.first
    }

    private let key = "sites_data_v2"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Site].self, from: data) {
            self.sites = decoded
        } else {
            self.sites = []
        }
        if let idStr = UserDefaults.standard.string(forKey: "currentSiteID") {
            self.currentSiteID = UUID(uuidString: idStr)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sites) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func addSite(_ site: Site) {
        sites.append(site)
        if sites.count == 1 { currentSiteID = site.id }
    }

    func removeSite(_ site: Site) {
        KeychainHelper.delete(key: site.id.uuidString)
        sites.removeAll { $0.id == site.id }
        if currentSiteID == site.id { currentSiteID = sites.first?.id }
    }

    func updateSite(_ site: Site) {
        if let idx = sites.firstIndex(where: { $0.id == site.id }) { sites[idx] = site }
    }

    func managementKey(for site: Site) -> String {
        KeychainHelper.load(key: site.id.uuidString)
    }

    func setManagementKey(_ key: String, for site: Site) {
        if key.isEmpty {
            KeychainHelper.delete(key: site.id.uuidString)
        } else {
            KeychainHelper.save(key: site.id.uuidString, value: key)
        }
    }
}
