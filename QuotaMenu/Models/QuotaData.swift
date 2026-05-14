import Foundation
import SwiftUI

struct QuotaItem: Identifiable, Equatable {
    let id: String
    let provider: String
    let account: String
    let name: String
    let plan: String?
    let status: String
    let error: String?
    var windows: [QuotaWindow]
    let extra: QuotaExtra?
    let fetchedAt: Date

    var isError: Bool { status == "error" }
    var displayProvider: String { Self.providerLabels[provider] ?? provider.uppercased() }
    var displayAccount: String { account }

    var providerColor: Color {
        switch provider {
        case "claude": Color(red: 0.37, green: 0.17, blue: 0.08)
        case "codex": Color(red: 0.15, green: 0.14, blue: 0.58)
        case "antigravity": Color(red: 0, green: 0.30, blue: 0.25)
        case "gemini-cli": Color(red: 0.11, green: 0.25, blue: 0.45)
        case "kimi": Color(red: 0, green: 0.22, blue: 0.50)
        default: Color.gray
        }
    }

    var providerTextColor: Color {
        switch provider {
        case "claude": Color(red: 0.91, green: 0.66, blue: 0.51)
        case "codex": Color(red: 0.71, green: 0.69, blue: 1.0)
        case "antigravity": Color(red: 0.50, green: 0.87, blue: 0.92)
        case "gemini-cli": Color(red: 0.66, green: 0.78, blue: 1.0)
        case "kimi": Color(red: 0.44, green: 0.71, blue: 1.0)
        default: Color.white
        }
    }

    static let providerLabels: [String: String] = [
        "claude": "Claude Code",
        "codex": "Codex",
        "antigravity": "Antigravity",
        "gemini-cli": "Gemini CLI",
        "kimi": "Kimi",
    ]

    static let providerOrder: [String] = ["claude", "codex", "antigravity", "gemini-cli", "kimi"]

    static func == (lhs: QuotaItem, rhs: QuotaItem) -> Bool { lhs.id == rhs.id }
}

struct QuotaWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let usedPercent: Double?
    let remainingPercent: Double?
    let resetAt: String?
    let detail: String?

    var remaining: Double { remainingPercent ?? 0 }

    var statusColor: Color {
        guard let pct = remainingPercent else { return .gray }
        if pct >= 70 { return .green }
        if pct >= 30 { return .orange }
        return .red
    }

    var resetTimeFormatted: String? {
        guard let raw = resetAt, !raw.isEmpty else { return nil }
        guard let date = Self.parseUTC(raw) else { return raw }

        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        let localStr = fmt.string(from: date)

        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return "\(localStr) (已重置)" }

        let totalMin = Int(diff / 60)
        let days = totalMin / 1440
        let hours = (totalMin % 1440) / 60
        let mins = totalMin % 60
        var countdown = ""
        if days > 0 { countdown += "\(days)d" }
        if hours > 0 { countdown += "\(hours)h" }
        if mins > 0 || countdown.isEmpty { countdown += "\(mins)m" }
        return "\(localStr) (\(countdown))"
    }

    private static func parseUTC(_ s: String) -> Date? {
        let fmts = ["yyyy-MM-dd HH:mm:ss 'UTC'", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"]
        for f in fmts {
            let df = DateFormatter()
            df.dateFormat = f
            df.timeZone = TimeZone(identifier: "UTC")
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}

struct QuotaExtra: Equatable {
    let label: String
    let used: String
    let limit: String
}
