import Foundation

actor QuotaFetcher {
    private var cache: [String: QuotaItem] = [:]
    private var cacheTimes: [String: Date] = [:]
    private let cacheTTL: TimeInterval = 300

    // MARK: - Public

    func fetchAll(site: Site, key: String) async -> [QuotaItem] {
        let files = await getAuthFiles(site: site, key: key)
        let now = Date()

        var tasks: [(String, AuthFile)] = []
        for f in files {
            guard let provider = resolveProvider(f), !isDisabled(f) else { continue }
            let cacheKey = accountKey(f)
            if let t = cacheTimes[cacheKey], now.timeIntervalSince(t) < cacheTTL { continue }
            tasks.append((provider, f))
        }

        await withTaskGroup(of: QuotaItem?.self) { group in
            for (provider, f) in tasks {
                group.addTask { await self.fetchOne(provider: provider, file: f, site: site, key: key) }
            }
            for await result in group {
                if let r = result {
                    let k = "\(r.provider):\(r.account)"
                    cache[k] = r
                    cacheTimes[k] = Date()
                }
            }
        }
        return Array(cache.values)
    }

    func refreshAll(site: Site, key: String) async -> [QuotaItem] {
        cache.removeAll()
        cacheTimes.removeAll()

        let files = await getAuthFiles(site: site, key: key)
        await withTaskGroup(of: QuotaItem?.self) { group in
            for f in files {
                guard let provider = resolveProvider(f), !isDisabled(f) else { continue }
                group.addTask { await self.fetchOne(provider: provider, file: f, site: site, key: key) }
            }
            for await result in group {
                if let r = result {
                    let k = "\(r.provider):\(r.account)"
                    cache[k] = r
                    cacheTimes[k] = Date()
                }
            }
        }
        return Array(cache.values)
    }

    func refreshAccount(site: Site, key: String, accountName: String) async -> [QuotaItem] {
        let files = await getAuthFiles(site: site, key: key)
        if let f = files.first(where: { ($0.name) == accountName || ($0.account ?? $0.email ?? $0.label ?? "") == accountName }) {
            if let provider = resolveProvider(f) {
                if let r = await fetchOne(provider: provider, file: f, site: site, key: key) {
                    let k = "\(r.provider):\(r.account)"
                    cache[k] = r
                    cacheTimes[k] = Date()
                }
            }
        }
        return Array(cache.values)
    }

    // MARK: - Auth Files

    private func getAuthFiles(site: Site, key: String) async -> [AuthFile] {
        guard let url = site.authFilesURL else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
            let decoded = try JSONDecoder().decode(AuthFilesResponse.self, from: data)
            return decoded.files ?? []
        } catch { return [] }
    }

    private func downloadAuthFile(site: Site, key: String, name: String) async -> [String: Any]? {
        guard let url = site.downloadURL(name: name) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }
    }

    // MARK: - API Call proxy

    private func apiCall(site: Site, key: String, authIndex: String, method: String, url: String, headers: [String: String], data: String? = nil) async throws -> APICallResponse {
        guard let apiURL = site.apiCallURL else { throw QuotaError.noURL }
        var payload: [String: Any] = [
            "authIndex": authIndex,
            "method": method,
            "url": url,
            "header": headers,
        ]
        if let data { payload["data"] = data }

        var req = URLRequest(url: apiURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw QuotaError.badResponse
        }
        if http.statusCode == 401 { throw QuotaError.unauthorized }
        do {
            return try JSONDecoder().decode(APICallResponse.self, from: respData)
        } catch {
            let text = String(data: respData, encoding: .utf8) ?? ""
            throw QuotaError.decodeFailed(text)
        }
    }

    // MARK: - Dispatch

    private func fetchOne(provider: String, file: AuthFile, site: Site, key: String) async -> QuotaItem? {
        do {
            switch provider {
            case "claude": return try await fetchClaude(file: file, site: site, key: key)
            case "codex": return try await fetchCodex(file: file, site: site, key: key)
            case "antigravity": return try await fetchAntigravity(file: file, site: site, key: key)
            case "gemini-cli": return try await fetchGeminiCLI(file: file, site: site, key: key)
            case "kimi": return try await fetchKimi(file: file, site: site, key: key)
            default: return nil
            }
        } catch {
            let existing = cache["\(provider):\(file.accountName)"]
            if let existing, !existing.isError { return existing }
            return errorResult(provider: provider, file: file, error: error.localizedDescription)
        }
    }

    // MARK: - Claude

    private func fetchClaude(file: AuthFile, site: Site, key: String) async throws -> QuotaItem {
        let authIndex = file.authIndex
        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
        ]

        async let usageTask = apiCall(site: site, key: key, authIndex: authIndex, method: "GET",
                                       url: "https://api.anthropic.com/api/oauth/usage", headers: headers)
        async let profileTask = apiCall(site: site, key: key, authIndex: authIndex, method: "GET",
                                         url: "https://api.anthropic.com/api/oauth/profile", headers: headers)

        let usageResult = try await usageTask
        guard (200..<300).contains(usageResult.statusCode) else {
            return errorResult(provider: "claude", file: file, error: "HTTP \(usageResult.statusCode)")
        }

        guard let usageBody = usageResult.bodyDict else {
            return errorResult(provider: "claude", file: file, error: "Empty usage response")
        }

        let windowKeys: [(String, String)] = [
            ("five_hour", "5小时窗口"), ("seven_day", "7天窗口"),
            ("seven_day_oauth_apps", "7天 OAuth Apps"), ("seven_day_opus", "7天 Opus"),
            ("seven_day_sonnet", "7天 Sonnet"), ("seven_day_cowork", "7天 Cowork"),
            ("iguana_necktie", "Iguana Necktie"),
        ]

        var windows: [QuotaWindow] = []
        for (wkey, label) in windowKeys {
            guard let w = usageBody[wkey] as? [String: Any] else { continue }
            guard let utilization = num(w["utilization"]) else { continue }
            let usedPct = round(utilization * 10) / 10
            let remainPct = round(max(0, min(100, 100 - usedPct)) * 10) / 10
            let resetAt = formatResetTime(w["resets_at"])
            windows.append(QuotaWindow(id: "\(file.accountName):\(label)", label: label,
                                       usedPercent: usedPct, remainingPercent: remainPct, resetAt: resetAt, detail: nil))
        }

        // Plan from profile
        var plan: String?
        let profileResult = try? await profileTask
        if let pb = profileResult?.bodyDict {
            let account = pb["account"] as? [String: Any] ?? [:]
            let org = pb["organization"] as? [String: Any] ?? [:]
            if account["has_claude_max"] as? Bool == true { plan = "Max" }
            else if account["has_claude_pro"] as? Bool == true { plan = "Pro" }
            else if (org["organization_type"] as? String) == "claude_team" && (org["subscription_status"] as? String) == "active" { plan = "Team" }
            else if account["has_claude_max"] as? Bool == false && account["has_claude_pro"] as? Bool == false { plan = "Free" }
        }

        // Extra usage
        var extra: QuotaExtra?
        if let eu = usageBody["extra_usage"] as? [String: Any], eu["is_enabled"] as? Bool == true {
            let used = (num(eu["used_credits"]) ?? 0) / 100
            let limit = (num(eu["monthly_limit"]) ?? 0) / 100
            extra = QuotaExtra(label: "额外用量", used: String(format: "$%.2f", used), limit: String(format: "$%.2f", limit))
        }

        return QuotaItem(id: "claude:\(file.accountName)", provider: "claude", account: file.accountName,
                         name: file.name, plan: plan, status: "success", error: nil,
                         windows: windows, extra: extra, fetchedAt: Date())
    }

    // MARK: - Codex

    private func fetchCodex(file: AuthFile, site: Site, key: String) async throws -> QuotaItem {
        let authIndex = file.authIndex
        let idToken = file.idToken ?? [:]
        let accountId = idToken["chatgpt_account_id"] as? String ?? idToken["chatgptAccountId"] as? String

        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal",
        ]
        if let accountId { headers["Chatgpt-Account-Id"] = accountId }

        let result = try await apiCall(site: site, key: key, authIndex: authIndex, method: "GET",
                                        url: "https://chatgpt.com/backend-api/wham/usage", headers: headers)
        guard (200..<300).contains(result.statusCode) else {
            return errorResult(provider: "codex", file: file, error: "HTTP \(result.statusCode)")
        }
        guard let body = result.bodyDict else {
            return errorResult(provider: "codex", file: file, error: "Empty response")
        }

        let planType = body["plan_type"] as? String ?? body["planType"] as? String
            ?? idToken["plan_type"] as? String ?? idToken["planType"] as? String

        var windows: [QuotaWindow] = []
        let rateLimit = body["rate_limit"] as? [String: Any] ?? body["rateLimit"] as? [String: Any] ?? [:]

        for (wkey, defaultLabel) in [("primary_window", "5小时窗口"), ("secondary_window", "7天窗口")] {
            let w = rateLimit[wkey] as? [String: Any]
                ?? rateLimit[wkey.replacingOccurrences(of: "_w", with: "W").replacingOccurrences(of: "_window", with: "Window")] as? [String: Any]
            guard let w else { continue }

            let limitSecs = num(w["limit_window_seconds"] ?? w["limitWindowSeconds"])
            var label = defaultLabel
            if limitSecs == 604800 { label = "7天窗口" }
            else if limitSecs == 18000 { label = "5小时窗口" }

            let usedPct = num(w["used_percent"] ?? w["usedPercent"])
            let resetAtRaw = num(w["reset_at"] ?? w["resetAt"])
            var resetLabel: String?
            if let ra = resetAtRaw { resetLabel = formatUnixSeconds(ra) }
            if resetLabel == nil {
                let resetAfter = num(w["reset_after_seconds"] ?? w["resetAfterSeconds"])
                if let ra = resetAfter, ra > 0 { resetLabel = formatUnixSeconds(Date().timeIntervalSince1970 + ra) }
            }

            let remain = usedPct != nil ? max(0, min(100, 100 - usedPct!)) : nil
            windows.append(QuotaWindow(id: "\(file.accountName):\(label)", label: label,
                                       usedPercent: usedPct, remainingPercent: remain, resetAt: resetLabel, detail: nil))
        }

        // Additional rate limits
        let additional = body["additional_rate_limits"] as? [[String: Any]] ?? body["additionalRateLimits"] as? [[String: Any]] ?? []
        for item in additional {
            let name = (item["limit_name"] ?? item["limitName"] ?? item["metered_feature"] ?? item["meteredFeature"]) as? String ?? "Additional"
            let rl = item["rate_limit"] as? [String: Any] ?? item["rateLimit"] as? [String: Any] ?? [:]
            for (wk, suffix) in [("primary_window", "5小时"), ("secondary_window", "7天")] {
                let w = rl[wk] as? [String: Any]
                    ?? rl[wk.replacingOccurrences(of: "_w", with: "W").replacingOccurrences(of: "_window", with: "Window")] as? [String: Any]
                guard let w else { continue }
                let usedPct = num(w["used_percent"] ?? w["usedPercent"])
                let resetAtRaw = num(w["reset_at"] ?? w["resetAt"])
                var resetLabel: String?
                if let ra = resetAtRaw { resetLabel = formatUnixSeconds(ra) }
                if resetLabel == nil {
                    let ra = num(w["reset_after_seconds"] ?? w["resetAfterSeconds"])
                    if let ra, ra > 0 { resetLabel = formatUnixSeconds(Date().timeIntervalSince1970 + ra) }
                }
                let remain = usedPct != nil ? max(0, min(100, 100 - usedPct!)) : nil
                let wLabel = "\(name) \(suffix)"
                windows.append(QuotaWindow(id: "\(file.accountName):\(wLabel)", label: wLabel,
                                           usedPercent: usedPct, remainingPercent: remain, resetAt: resetLabel, detail: nil))
            }
        }

        return QuotaItem(id: "codex:\(file.accountName)", provider: "codex", account: file.accountName,
                         name: file.name, plan: Self.codexPlanLabel(planType), status: "success", error: nil,
                         windows: windows, extra: nil, fetchedAt: Date())
    }

    // MARK: - Codex plan label mapping

    private static func codexPlanLabel(_ raw: String?) -> String? {
        guard let r = raw?.lowercased().trimmingCharacters(in: .whitespaces), !r.isEmpty else { return raw }
        switch r {
        case "pro": return "Pro 20x"
        case "prolite", "pro-lite", "pro_lite": return "Pro 5x"
        case "plus": return "Plus"
        case "team": return "Team"
        case "free": return "Free"
        default: return raw
        }
    }

    // MARK: - Antigravity

    private static let antigravityURLs = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
        "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
    ]

    private static let antigravityGroups: [(id: String, label: String, identifiers: [String])] = [
        ("claude-gpt", "Claude/GPT", ["claude-sonnet-4-6", "claude-opus-4-6-thinking", "gpt-oss-120b-medium"]),
        ("gemini-3-pro", "Gemini 3 Pro", ["gemini-3-pro-high", "gemini-3-pro-low"]),
        ("gemini-3-1-pro-series", "Gemini 3.1 Pro Series", ["gemini-3.1-pro-high", "gemini-3.1-pro-low"]),
        ("gemini-2-5-flash", "Gemini 2.5 Flash", ["gemini-2.5-flash", "gemini-2.5-flash-thinking"]),
        ("gemini-2-5-flash-lite", "Gemini 2.5 Flash Lite", ["gemini-2.5-flash-lite"]),
        ("gemini-2-5-cu", "Gemini 2.5 CU", ["rev19-uic3-1p"]),
        ("gemini-3-flash", "Gemini 3 Flash", ["gemini-3-flash"]),
        ("gemini-image", "gemini-3.1-flash-image", ["gemini-3.1-flash-image"]),
    ]

    private func fetchAntigravity(file: AuthFile, site: Site, key: String) async throws -> QuotaItem {
        let authIndex = file.authIndex
        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": "antigravity/1.11.5 windows/amd64",
        ]

        var projectId = "bamboo-precept-lgxtn"
        if let parsed = await downloadAuthFile(site: site, key: key, name: file.name) {
            projectId = parsed["project_id"] as? String
                ?? parsed["projectId"] as? String
                ?? (parsed["installed"] as? [String: Any])?["project_id"] as? String
                ?? (parsed["installed"] as? [String: Any])?["projectId"] as? String
                ?? (parsed["web"] as? [String: Any])?["project_id"] as? String
                ?? (parsed["web"] as? [String: Any])?["projectId"] as? String
                ?? projectId
        }

        let postData = try JSONSerialization.data(withJSONObject: ["project": projectId])
        let postStr = String(data: postData, encoding: .utf8)!

        var lastError = "All URLs failed"
        for url in Self.antigravityURLs {
            do {
                let result = try await apiCall(site: site, key: key, authIndex: authIndex, method: "POST", url: url, headers: headers, data: postStr)
                guard (200..<300).contains(result.statusCode) else { lastError = "HTTP \(result.statusCode)"; continue }

                var body = result.bodyDict
                if body != nil && body!["models"] == nil {
                    if let nested = body!["body"] as? String, let d = nested.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { body = parsed }
                }
                guard let models = body?["models"] as? [String: Any] else { lastError = "Empty models"; continue }

                var groups: [QuotaWindow] = []
                for gdef in Self.antigravityGroups {
                    var minFraction: Double?
                    var resetTime: Any?
                    var matched = false

                    for ident in gdef.identifiers {
                        var model = models[ident] as? [String: Any]
                        if model == nil {
                            for (_, mv) in models {
                                guard let mv = mv as? [String: Any] else { continue }
                                let dn = mv["displayName"] as? String ?? ""
                                if dn.lowercased() == ident.lowercased() { model = mv; break }
                            }
                        }
                        guard let model else { continue }
                        let qi = model["quotaInfo"] as? [String: Any] ?? model["quota_info"] as? [String: Any] ?? [:]
                        let frac = num(qi["remainingFraction"] ?? qi["remaining_fraction"] ?? qi["remaining"])
                        let rt = qi["resetTime"] ?? qi["reset_time"]
                        if let frac { matched = true; if minFraction == nil || frac < minFraction! { minFraction = frac } }
                        if rt != nil && resetTime == nil { resetTime = rt; if frac == nil { matched = true; minFraction = 0 } }
                    }

                    if matched {
                        let remainPct = round((minFraction ?? 0) * 1000) / 10
                        groups.append(QuotaWindow(id: "\(file.accountName):\(gdef.label)", label: gdef.label,
                                                  usedPercent: round(100 - remainPct, 1), remainingPercent: remainPct,
                                                  resetAt: formatResetTime(resetTime), detail: nil))
                    }
                }

                return QuotaItem(id: "antigravity:\(file.accountName)", provider: "antigravity", account: file.accountName,
                                 name: file.name, plan: "Cloud Code", status: "success", error: nil,
                                 windows: groups, extra: nil, fetchedAt: Date())
            } catch { lastError = error.localizedDescription; continue }
        }
        return errorResult(provider: "antigravity", file: file, error: lastError)
    }

    // MARK: - Gemini CLI

    private static let geminiCLIGroups: [(id: String, label: String, modelIds: [String])] = [
        ("gemini-flash-lite-series", "Gemini Flash Lite Series", ["gemini-2.5-flash-lite"]),
        ("gemini-flash-series", "Gemini Flash Series", ["gemini-3-flash-preview", "gemini-2.5-flash"]),
        ("gemini-pro-series", "Gemini Pro Series", ["gemini-3.1-pro-preview", "gemini-3-pro-preview", "gemini-2.5-pro"]),
    ]

    private func fetchGeminiCLI(file: AuthFile, site: Site, key: String) async throws -> QuotaItem {
        let authIndex = file.authIndex
        let headers = ["Authorization": "Bearer $TOKEN$", "Content-Type": "application/json"]

        guard let parsed = await downloadAuthFile(site: site, key: key, name: file.name) else {
            return errorResult(provider: "gemini-cli", file: file, error: "Cannot download auth file")
        }
        let projectId = parsed["project_id"] as? String ?? parsed["projectId"] as? String
            ?? (parsed["installed"] as? [String: Any])?["project_id"] as? String
            ?? (parsed["installed"] as? [String: Any])?["projectId"] as? String
        guard let projectId else { return errorResult(provider: "gemini-cli", file: file, error: "Missing project ID") }

        let postData = try JSONSerialization.data(withJSONObject: ["project": projectId])
        let postStr = String(data: postData, encoding: .utf8)!

        let result = try await apiCall(site: site, key: key, authIndex: authIndex, method: "POST",
                                        url: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota", headers: headers, data: postStr)
        guard (200..<300).contains(result.statusCode) else {
            return errorResult(provider: "gemini-cli", file: file, error: "HTTP \(result.statusCode)")
        }
        guard let body = result.bodyDict else {
            return errorResult(provider: "gemini-cli", file: file, error: "Empty response")
        }

        let rawBuckets = body["buckets"] as? [[String: Any]] ?? []
        var buckets: [String: (frac: Double?, rt: Any?)] = [:]
        for b in rawBuckets {
            var modelId = b["modelId"] as? String ?? b["model_id"] as? String ?? ""
            if modelId.hasSuffix("_vertex") { modelId = String(modelId.dropLast(7)) }
            guard !modelId.isEmpty else { continue }
            var frac = num(b["remainingFraction"] ?? b["remaining_fraction"])
            let amount = num(b["remainingAmount"] ?? b["remaining_amount"])
            let rt = b["resetTime"] ?? b["reset_time"]
            if frac == nil { if amount != nil && amount! <= 0 { frac = 0 } else if rt != nil { frac = 0 } }
            buckets[modelId] = (frac, rt)
        }

        var windows: [QuotaWindow] = []
        for gdef in Self.geminiCLIGroups {
            var minFrac: Double?
            var resetTime: Any?
            for mid in gdef.modelIds {
                guard let bkt = buckets[mid] else { continue }
                if let f = bkt.frac { if minFrac == nil || f < minFrac! { minFrac = f } }
                if bkt.rt != nil && resetTime == nil { resetTime = bkt.rt }
            }
            if let minFrac {
                let remainPct = round(minFrac * 1000) / 10
                windows.append(QuotaWindow(id: "\(file.accountName):\(gdef.label)", label: gdef.label,
                                           usedPercent: round(100 - remainPct, 1), remainingPercent: remainPct,
                                           resetAt: formatResetTime(resetTime), detail: nil))
            }
        }

        // Get tier
        var tierLabel: String?
        do {
            let caResult = try await apiCall(site: site, key: key, authIndex: authIndex, method: "POST",
                                              url: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
                                              headers: headers, data: postStr)
            if (200..<300).contains(caResult.statusCode), let cb = caResult.bodyDict {
                let tier = cb["currentTier"] as? [String: Any] ?? cb["current_tier"] as? [String: Any]
                tierLabel = tier?["name"] as? String ?? tier?["id"] as? String
            }
        } catch {}

        return QuotaItem(id: "gemini-cli:\(file.accountName)", provider: "gemini-cli", account: file.accountName,
                         name: file.name, plan: tierLabel ?? "Gemini CLI", status: "success", error: nil,
                         windows: windows, extra: nil, fetchedAt: Date())
    }

    // MARK: - Kimi

    private func fetchKimi(file: AuthFile, site: Site, key: String) async throws -> QuotaItem {
        let authIndex = file.authIndex
        let headers = ["Authorization": "Bearer $TOKEN$"]

        let result = try await apiCall(site: site, key: key, authIndex: authIndex, method: "GET",
                                        url: "https://api.kimi.com/coding/v1/usages", headers: headers)
        guard (200..<300).contains(result.statusCode) else {
            return errorResult(provider: "kimi", file: file, error: "HTTP \(result.statusCode)")
        }
        guard let body = result.bodyDict else {
            return errorResult(provider: "kimi", file: file, error: "Empty response")
        }

        var rows: [QuotaWindow] = []
        let limits = body["limits"] as? [[String: Any]] ?? []
        for item in limits {
            let name = item["title"] as? String ?? item["name"] as? String ?? "Limit"
            let detail = item["detail"] as? [String: Any] ?? item
            let used = num(detail["used"]) ?? 0
            let limit = num(detail["limit"]) ?? 0
            let usedPct = limit > 0 ? round(used / limit * 1000) / 10 : (used > 0 ? 100 : 0)
            let remainPct = round(max(0, 100 - usedPct) * 10) / 10

            var resetHint: String?
            let rt = detail["resetAt"] ?? detail["reset_at"] ?? detail["resetTime"] ?? detail["reset_time"]
            if rt != nil { resetHint = formatResetTime(rt) }
            else {
                let ttl = num(detail["ttl"] ?? detail["resetIn"] ?? detail["reset_in"])
                if let ttl, ttl > 0 { resetHint = formatUnixSeconds(Date().timeIntervalSince1970 + ttl) }
            }

            let detailStr = limit > 0 ? "\(Int(used))/\(Int(limit))" : "\(Int(used))"
            rows.append(QuotaWindow(id: "\(file.accountName):\(name)", label: name,
                                    usedPercent: usedPct, remainingPercent: remainPct,
                                    resetAt: resetHint, detail: detailStr))
        }

        if rows.isEmpty, let usage = body["usage"] as? [String: Any] {
            let used = num(usage["used"]) ?? 0
            let limit = num(usage["limit"]) ?? 0
            let usedPct = limit > 0 ? round(used / limit * 1000) / 10 : (used > 0 ? 100 : 0)
            rows.append(QuotaWindow(id: "\(file.accountName):Usage", label: "Usage",
                                    usedPercent: usedPct, remainingPercent: round(max(0, 100 - usedPct), 1),
                                    resetAt: nil, detail: limit > 0 ? "\(Int(used))/\(Int(limit))" : "\(Int(used))"))
        }

        return QuotaItem(id: "kimi:\(file.accountName)", provider: "kimi", account: file.accountName,
                         name: file.name, plan: "Kimi", status: "success", error: nil,
                         windows: rows, extra: nil, fetchedAt: Date())
    }

    // MARK: - Helpers

    private func resolveProvider(_ f: AuthFile) -> String? {
        for key in [f.provider, f.type] {
            if let k = key, !k.isEmpty { return k.lowercased() }
        }
        let nl = f.name.lowercased()
        if nl.hasPrefix("codex-") { return "codex" }
        if nl.hasPrefix("claude-") { return "claude" }
        if nl.contains("antigravity") || nl.contains("cloudcode") { return "antigravity" }
        if nl.contains("gemini") { return "gemini-cli" }
        if nl.contains("kimi") { return "kimi" }
        return nil
    }

    private func isDisabled(_ f: AuthFile) -> Bool { f.disabled == true }
    private func accountKey(_ f: AuthFile) -> String { "\(resolveProvider(f) ?? ""):\(f.accountName)" }

    private func errorResult(provider: String, file: AuthFile, error: String) -> QuotaItem {
        QuotaItem(id: "\(provider):\(file.accountName)", provider: provider, account: file.accountName,
                  name: file.name, plan: nil, status: "error", error: error,
                  windows: [], extra: nil, fetchedAt: Date())
    }

    private func num(_ v: Any?) -> Double? {
        if let n = v as? Double { return n.isNaN ? nil : n }
        if let n = v as? Int { return Double(n) }
        if let s = v as? String, let n = Double(s) { return n }
        return nil
    }

    private func round(_ v: Double, _ places: Int = 1) -> Double {
        let m = pow(10.0, Double(places))
        return Darwin.round(v * m) / m
    }

    private func formatUnixSeconds(_ ts: Double) -> String? {
        guard ts > 0 else { return nil }
        let date = Date(timeIntervalSince1970: ts)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    private func formatResetTime(_ v: Any?) -> String? {
        guard let v else { return nil }
        if let n = num(v), n > 0 {
            var ts = n
            if ts < 1e12 { ts *= 1000 }
            return formatUnixSeconds(ts / 1000)
        }
        if let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
            return s.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

// MARK: - DTOs

struct AuthFile: Codable {
    let name: String
    let provider: String?
    let type: String?
    let account: String?
    let email: String?
    let label: String?
    let disabled: Bool?
    let auth_index: String?
    let id_token: AnyCodable?

    private struct DynKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynKey.self)
        name = try c.decodeIfPresent(String.self, forKey: DynKey(stringValue: "name")!) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: DynKey(stringValue: "provider")!)
        type = try c.decodeIfPresent(String.self, forKey: DynKey(stringValue: "type")!)
        account = try c.decodeIfPresent(String.self, forKey: DynKey(stringValue: "account")!)
        email = try c.decodeIfPresent(String.self, forKey: DynKey(stringValue: "email")!)
        label = try c.decodeIfPresent(String.self, forKey: DynKey(stringValue: "label")!)
        disabled = try c.decodeIfPresent(Bool.self, forKey: DynKey(stringValue: "disabled")!)
        auth_index = try c.decodeIfPresent(String.self, forKey: DynKey(stringValue: "auth_index")!)
            ?? c.decodeIfPresent(String.self, forKey: DynKey(stringValue: "authIndex")!)
        id_token = try c.decodeIfPresent(AnyCodable.self, forKey: DynKey(stringValue: "id_token")!)
            ?? c.decodeIfPresent(AnyCodable.self, forKey: DynKey(stringValue: "idToken")!)
    }

    var authIndex: String { auth_index ?? "" }
    var accountName: String { account ?? email ?? label ?? name }
    var idToken: [String: Any]? {
        if let dict = id_token?.value as? [String: Any] { return dict }
        if let str = id_token?.value as? String, let d = str.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return parsed }
        return nil
    }
}

struct AuthFilesResponse: Codable {
    let files: [AuthFile]?
}

struct APICallResponse: Codable {
    let status_code: Int?
    let statusCodeCamel: Int?
    let body: AnyCodable?
    let bodyText: String?

    private enum CodingKeys: String, CodingKey {
        case status_code
        case statusCodeCamel = "statusCode"
        case body, bodyText
    }

    var statusCode: Int { status_code ?? statusCodeCamel ?? 0 }

    var bodyDict: [String: Any]? {
        if let dict = body?.value as? [String: Any] { return dict }
        if let text = bodyText ?? (body?.value as? String),
           let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return parsed }
        return nil
    }
}

// Generic Codable wrapper for Any
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a.map { $0.value } }
        else if let d = try? container.decode([String: AnyCodable].self) { value = d.mapValues { $0.value } }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        default: try container.encodeNil()
        }
    }
}

enum QuotaError: Error, LocalizedError {
    case noURL
    case badResponse
    case unauthorized
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noURL: "Invalid URL"
        case .badResponse: "Bad response"
        case .unauthorized: "Unauthorized"
        case .decodeFailed(let text): "Decode failed: \(text.prefix(200))"
        }
    }
}
