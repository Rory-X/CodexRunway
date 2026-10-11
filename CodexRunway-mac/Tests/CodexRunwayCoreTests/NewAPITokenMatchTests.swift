import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("New API token matching")
struct NewAPITokenMatchTests {
    @Test("masked dashboard keys match the live sk- secret by prefix and suffix")
    func maskedKeyMatchesRelaySecret() {
        #expect(NewAPITokenKeyMatch.matches(
            relayKey: "sk-KOEfRhiddenSuffixKPnf",
            listedKey: "KOEf**********KPnf"))
        #expect(NewAPITokenKeyMatch.matches(
            relayKey: "sk-KOEfRhiddenSuffixKPnf",
            listedKey: "sk-KOEf**********KPnf"))
        #expect(!NewAPITokenKeyMatch.matches(
            relayKey: "sk-KOEfRhiddenSuffixKPnf",
            listedKey: "et7W**********93hP"))
        #expect(!NewAPITokenKeyMatch.matches(
            relayKey: "sk-KOEfRhiddenSuffixKPnf",
            listedKey: "KOEf**********xxxx"))
    }

    @Test("the matching token name is the one that belongs to this key")
    func resolvesNameForThisKey() {
        let tokens = [
            (name: "kunkun", key: "et7W**********93hP"),
            (name: "ccodex", key: "KOEf**********KPnf"),
            (name: "cc", key: "bfTV**********wtnf"),
        ]
        #expect(NewAPITokenKeyMatch.tokenName(
            relayKey: "sk-KOEfRhiddenSuffixKPnf",
            tokens: tokens) == "ccodex")
        #expect(NewAPITokenKeyMatch.tokenName(
            relayKey: "sk-unknown",
            tokens: tokens) == nil)
    }

    @Test("token list JSON accepts both items-object and bare-array payloads")
    func tokenListDecodesBothShapes() throws {
        let paged = try JSONDecoder().decode(
            NewAPITokenListResponse.self,
            from: Data(#"{"data":{"items":[{"name":"ccodex","key":"KOEf**********KPnf"}]}}"#.utf8))
        #expect(paged.rows.map(\.name) == ["ccodex"])

        let array = try JSONDecoder().decode(
            NewAPITokenListResponse.self,
            from: Data(#"{"data":[{"name":"cc","key":"bfTV**********wtnf"}]}"#.utf8))
        #expect(array.rows.map(\.name) == ["cc"])
    }

    @Test("relay quota snapshot keeps the per-key daily series")
    func makeRelayQuotaStoresDailySeries() {
        let now = Date(timeIntervalSince1970: 1_789_545_600) // 2026-09-16 00:00 UTC
        let day = NewAPIDailyUsage.dayKey(now)
        let quota = AccountQuotaRefresher.makeRelayQuota(
            usage: NewAPIAccountUsage(
                remainingQuota: 954_911,
                usedQuota: 31_545_089,
                requestCount: 1_317,
                displayName: "Rory",
                group: "default"),
            daily: NewAPIDailyUsage(tokensByDay: [day: 33_300]),
            tokenName: "ccodex",
            now: now)
        #expect(quota.newAPI?.tokenName == "ccodex")
        #expect(quota.newAPI?.tokensByDay?[day] == 33_300)
        #expect(quota.newAPI?.todayTokens == 33_300)
    }
}
