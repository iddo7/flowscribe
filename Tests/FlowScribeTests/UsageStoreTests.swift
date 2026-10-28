import XCTest
@testable import FlowScribe

final class UsageStoreTests: XCTestCase {
    func testSuccessfulRequestsUseProviderUnitsAndKeepCreditCountsSeparateFromDollars() {
        let store = UsageStore(defaults: nil)
        let speech = store.begin(provider: .elevenLabs, model: "eleven_multilingual_v2", units: 1000)
        store.finish(speech, status: 200, reportedCredits: 1100)
        let dictation = store.begin(provider: .openAI, model: "gpt-transcribe", units: 120)
        store.finish(dictation, status: 200)
        let total = store.snapshot().totals()
        XCTAssertEqual(total.estimatedUSD, 0.089, accuracy: 0.000001)
        XCTAssertEqual(total.requests, 2)
        XCTAssertEqual(total.characters, 1000)
        XCTAssertEqual(total.audioSeconds, 120)
        XCTAssertEqual(total.reportedCredits, 1100)
        XCTAssertEqual(total.requestsWithCredits, 1)
        XCTAssertEqual(total.unconfirmedRequests, 0)
        XCTAssertEqual(store.snapshot().totals(provider: .openAI).requests, 1)
    }

    func testInterruptedAndServerErrorRequestsRemainSeparateFromConfirmedCost() {
        let store = UsageStore(defaults: nil)
        for status: Int? in [nil, 500] {
            let ticket = store.begin(provider: .elevenLabs, model: "eleven_multilingual_v2", units: 1000)
            store.finish(ticket, status: status)
        }
        let total = store.snapshot().totals()
        XCTAssertEqual(total.estimatedUSD, 0)
        XCTAssertEqual(total.requests, 0)
        XCTAssertEqual(total.unconfirmedRequests, 2)
        XCTAssertEqual(total.unconfirmedUSD, 0.16, accuracy: 0.000001)
    }

    func testRejectedRequestsAreNotChargedAndDuplicateCompletionIsIgnored() {
        let store = UsageStore(defaults: nil)
        let rejected = store.begin(provider: .openAI, model: "gpt-transcribe", units: 60)
        store.finish(rejected, status: 401)
        store.finish(rejected, status: 200)
        let success = store.begin(provider: .openAI, model: "gpt-transcribe", units: 60)
        store.finish(success, status: 200)
        store.finish(success, status: 200)
        let total = store.snapshot().totals()
        XCTAssertEqual(total.requests, 1)
        XCTAssertEqual(total.unconfirmedRequests, 0)
        XCTAssertEqual(total.estimatedUSD, 0.0045, accuracy: 0.000001)
    }

    func testUnknownModelsAndUnknownDurationAreVisibleAsUnpricedUsage() {
        let store = UsageStore(defaults: nil)
        store.finish(store.begin(provider: .openAI, model: "custom-model", units: 60), status: 200)
        store.finish(store.begin(provider: .openAI, model: "gpt-transcribe", units: nil), status: 200)
        let total = store.snapshot().totals()
        XCTAssertEqual(total.requests, 2)
        XCTAssertEqual(total.unpricedRequests, 2)
        XCTAssertEqual(total.estimatedUSD, 0)
    }

    func testDailyAndMonthlyTotalsAcrossMonthBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var now = ISO8601DateFormatter().date(from: "2026-10-31T23:59:00Z")!
        let store = UsageStore(defaults: nil, now: { now }, calendar: calendar)
        let ticket = store.begin(provider: .openAI, model: "gpt-transcribe", units: 60)
        now = ISO8601DateFormatter().date(from: "2026-11-01T00:01:00Z")!
        store.finish(ticket, status: 200)
        store.finish(store.begin(provider: .openAI, model: "gpt-transcribe", units: 60), status: 200)
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.totals().requests, 2)
        XCTAssertEqual(snapshot.totals(in: calendar.dateInterval(of: .month, for: now)).requests, 1)
        XCTAssertEqual(snapshot.totals(in: calendar.dateInterval(of: .day, for: now)).requests, 1)
    }

    func testPersistenceRetainsUnconfirmedRequestsAndRateChangesDoNotRewriteHistory() {
        let suite = "FlowScribe.UsageTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults)
        let old = store.begin(provider: .elevenLabs, model: "eleven_v3", units: 1000)
        store.finish(old, status: 200)
        defaults.set(0.0002, forKey: UsagePricing.key(.elevenLabs, "eleven_v3"))
        store.finish(store.begin(provider: .elevenLabs, model: "eleven_v3", units: 1000), status: 200)
        _ = store.begin(provider: .elevenLabs, model: "eleven_v3", units: 1000) // App exits before a response.
        let reloaded = UsageStore(defaults: defaults).snapshot()
        XCTAssertEqual(reloaded.totals().estimatedUSD, 0.28, accuracy: 0.000001)
        XCTAssertEqual(reloaded.totals().unconfirmedRequests, 1)
        XCTAssertEqual(reloaded.startedAt, store.snapshot().startedAt)
        let encoded = String(data: defaults.data(forKey: "usage.buckets")!, encoding: .utf8)!
        XCTAssertFalse(encoded.contains("text"))
        XCTAssertFalse(encoded.contains("key"))
    }

    func testConcurrentRequestsDoNotLoseUpdates() {
        let store = UsageStore(defaults: nil)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            store.finish(store.begin(provider: .elevenLabs, model: "eleven_flash_v2_5", units: 100), status: 200)
        }
        XCTAssertEqual(store.snapshot().totals().requests, 100)
        XCTAssertEqual(store.snapshot().totals().estimatedUSD, 0.4, accuracy: 0.000001)
        XCTAssertEqual(store.snapshot().totals().unconfirmedRequests, 0)
    }

    func testCanonicalWAVDurationAndMalformedData() {
        var wav = WAVHeader.make(sampleRate: 16_000, dataBytes: 64_000)
        wav.append(Data(repeating: 0, count: 64_000))
        XCTAssertEqual(WAVHeader.duration(of: wav), 2)
        XCTAssertNil(WAVHeader.duration(of: Data()))
        XCTAssertNil(WAVHeader.duration(of: wav.prefix(100)))
        var invalid = wav
        invalid[36] = 0
        XCTAssertNil(WAVHeader.duration(of: invalid))
    }
}
