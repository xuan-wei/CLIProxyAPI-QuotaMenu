import Foundation
import XCTest
// The unhosted test target compiles the production service/model sources.

final class ClaudeQuotaParserTests: XCTestCase {
    private let account = "test-account"

    private func limit(percent: Any, active: Any = false, name: String = "Fable") -> [String: Any] {
        ["kind": "weekly_scoped", "percent": percent, "is_active": active,
         "scope": ["model": ["display_name": name]]]
    }

    private func parse(_ body: [String: Any]) -> [QuotaWindow] {
        ClaudeQuotaParser.parseWindows(usageBody: body, accountName: account)
    }

    func testRejectsMalformedLimitShapesAndNonNumericPercent() {
        for bad in [NSNull(), "array", ["percent": 1]] as [Any] {
            XCTAssertTrue(parse(["limits": bad]).isEmpty)
        }
        for bad in [NSNull(), true, "42", Double.nan, Double.infinity, [], [:]] as [Any] {
            XCTAssertTrue(parse(["limits": [limit(percent: bad)]]).isEmpty)
        }
        XCTAssertTrue(parse(["limits": [
            ["kind": "weekly_scoped", "percent": 42, "scope": ["model": []]],
            ["kind": "weekly_scoped", "percent": 42, "scope": ["model": ["display_name": "Fable 6"]]],
        ]]).isEmpty)
    }

    func testJsonBooleanAndNumericActiveAreNotConfused() throws {
        // JSONSerialization bridges bool and number to NSNumber differently.
        let json = #"{"limits":[{"kind":"weekly_scoped","percent":11,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":22,"is_active":1,"scope":{"model":{"display_name":"Fable"}}}]}"#
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parse(body).first?.usedPercent, 11)
        let boolJSON = #"{"limits":[{"kind":"weekly_scoped","percent":true,"scope":{"model":{"display_name":"Fable"}}}]}"#
        let boolBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(boolJSON.utf8)) as? [String: Any])
        XCTAssertTrue(parse(boolBody).isEmpty)
    }

    func testFirstValidCandidateWinsWithoutTrueActive() {
        let windows = parse(["limits": [limit(percent: 11), limit(percent: 22, active: "true")]])
        XCTAssertEqual(windows.first?.usedPercent, 11)
    }

    func testInvalidModernCandidateFallsBackToLegacy() {
        let windows = parse([
            "iguana_necktie": ["utilization": "41", "resets_at": "legacy"],
            "limits": [limit(percent: NSNull(), active: true)],
        ])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.label, "Fable 5 周限额")
        XCTAssertEqual(windows.first?.usedPercent, 41)
        XCTAssertEqual(windows.first?.resetAt, "legacy")
    }

    func testEveryDollarMarkerPreventsLegacyMisidentification() {
        for key in ["limit_dollars", "used_dollars", "remaining_dollars"] {
            for value in [0, 100, "unknown"] as [Any] {
                let windows = parse(["iguana_necktie": ["utilization": 5, key: value]])
                XCTAssertEqual(windows.map(\.label), ["Iguana Necktie"])
            }
        }
        let windows = parse(["iguana_necktie": ["utilization": 5, "limit_dollars": NSNull()]])
        XCTAssertEqual(windows.first?.label, "Fable 5 周限额")
    }

    func testTraditionalWindowsAndResetFormatsArePreserved() {
        let windows = parse([
            "five_hour": ["utilization": 10, "resets_at": 1609459200],
            "seven_day": ["utilization": 20, "resets_at": 1609459200000],
            "seven_day_opus": ["utilization": 30, "resets_at": "2026-11-20T00:00:00Z"],
            "limits": [limit(percent: 40)],
        ])
        XCTAssertEqual(windows.map(\.label), ["5小时窗口", "7天窗口", "7天 Opus", "Fable 5 周限额"])
        XCTAssertEqual(windows[0].resetAt, "2021-01-01 00:00:00 UTC")
        XCTAssertEqual(windows[1].resetAt, windows[0].resetAt)
        XCTAssertEqual(windows[2].resetAt, "2026-11-20T00:00:00Z")
    }

    func testRemainingPercentIsClampedAndRounded() {
        XCTAssertEqual(parse(["limits": [limit(percent: 120)]]).first?.remainingPercent, 0)
        XCTAssertEqual(parse(["limits": [limit(percent: -10)]]).first?.remainingPercent, 100)
        let result = parse(["limits": [limit(percent: 64.16)]]).first
        XCTAssertEqual(result?.usedPercent, 64.2)
        XCTAssertEqual(result?.remainingPercent, 35.8)
    }

    func testParsesModernFableLimit() {
        let windows = ClaudeQuotaParser.parseWindows(usageBody: [
            "limits": [[
                "kind": "weekly_scoped",
                "percent": 64,
                "resets_at": "2026-11-20T00:00:00Z",
                "is_active": true,
                "scope": ["model": ["display_name": "Fable"]],
            ]],
        ], accountName: account)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].id, "test-account:seven-day-fable")
        XCTAssertEqual(windows[0].label, "Fable 5 周限额")
        XCTAssertEqual(windows[0].usedPercent, 64)
        XCTAssertEqual(windows[0].remainingPercent, 36)
        XCTAssertEqual(windows[0].resetAt, "2026-11-20T00:00:00Z")
    }

    func testAcceptsFable5NameAndPrefersStrictlyActiveCandidate() {
        let windows = ClaudeQuotaParser.parseWindows(usageBody: [
            "limits": [
                ["kind": "weekly_scoped", "percent": 12, "is_active": false,
                 "scope": ["model": ["display_name": "Fable 5"]]],
                ["kind": "weekly_scoped", "percent": 64, "is_active": true,
                 "scope": ["model": ["display_name": " fAbLe 5 "]]],
            ],
        ], accountName: account)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].usedPercent, 64)
    }

    func testInvalidActiveCandidateDoesNotBlockValidCandidate() {
        let windows = ClaudeQuotaParser.parseWindows(usageBody: [
            "limits": [
                ["kind": "weekly_scoped", "percent": "bad", "is_active": true,
                 "scope": ["model": ["display_name": "Fable"]]],
                ["kind": "weekly_scoped", "percent": 42, "is_active": "true",
                 "scope": ["model": ["display_name": "Fable"]]],
                ["kind": "weekly_scoped", "percent": 42,
                 "scope": ["model": ["display_name": "Fable"]]],
            ],
        ], accountName: account)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].usedPercent, 42)
    }

    func testMalformedOrUnrelatedLimitsAreSkipped() {
        let windows = ClaudeQuotaParser.parseWindows(usageBody: [
            "five_hour": ["utilization": 10],
            "limits": [
                NSNull(),
                ["kind": "session", "percent": 20, "scope": ["model": ["display_name": "Fable"]]],
                ["kind": "weekly_scoped", "percent": 20, "scope": ["model": ["display_name": "Sonnet"]]],
                ["kind": "weekly_scoped", "percent": true, "scope": ["model": ["display_name": "Fable"]]],
                ["kind": "weekly_scoped", "percent": 99, "scope": NSNull()],
            ],
        ], accountName: account)

        XCTAssertEqual(windows.map(\.label), ["5小时窗口"])
    }

    func testNoModernFableAddsNoWindow() {
        let windows = ClaudeQuotaParser.parseWindows(usageBody: [
            "limits": [],
        ], accountName: account)
        XCTAssertTrue(windows.isEmpty)
    }

    func testLegacyIguanaFallbackIsNamedFable() {
        let windows = ClaudeQuotaParser.parseWindows(usageBody: [
            "iguana_necktie": ["utilization": 41, "resets_at": "legacy-reset"],
        ], accountName: account)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].id, "test-account:seven-day-fable")
        XCTAssertEqual(windows[0].label, "Fable 5 周限额")
        XCTAssertEqual(windows[0].usedPercent, 41)
    }

    func testModernFableSuppressesNonDollarLegacyDuplicate() {
        let windows = ClaudeQuotaParser.parseWindows(usageBody: [
            "iguana_necktie": ["utilization": 41],
            "limits": [[
                "kind": "weekly_scoped", "percent": 64,
                "scope": ["model": ["display_name": "Fable"]],
            ]],
        ], accountName: account)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].usedPercent, 64)
    }

    func testDollarIguanaIsNotRenamedOrDropped() {
        let windows = ClaudeQuotaParser.parseWindows(usageBody: [
            "iguana_necktie": ["utilization": 5, "limit_dollars": 100, "used_dollars": 5],
            "limits": [[
                "kind": "weekly_scoped", "percent": 64,
                "scope": ["model": ["display_name": "Fable 5"]],
            ]],
        ], accountName: account)

        XCTAssertEqual(windows.map(\.label), ["Iguana Necktie", "Fable 5 周限额"])
    }

    func testModernPercentZeroIsValidAndRemainingIsClamped() {
        let windows = ClaudeQuotaParser.parseWindows(usageBody: [
            "limits": [[
                "kind": "weekly_scoped", "percent": 0,
                "scope": ["model": ["display_name": "Fable"]],
            ]],
        ], accountName: account)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].usedPercent, 0)
        XCTAssertEqual(windows[0].remainingPercent, 100)
        XCTAssertNil(windows[0].resetAt)
    }
}
