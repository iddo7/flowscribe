import Foundation

enum UsageProvider: String, Codable { case elevenLabs, openAI }

/// Published API estimates, checked 2026-10-28. User overrides apply to future requests.
/// https://elevenlabs.io/pricing/api
/// https://developers.openai.com/api/docs/pricing
enum UsagePricing {
    static func rate(provider: UsageProvider, model: String, defaults: UserDefaults?) -> Double? {
        if let number = defaults?.object(forKey: key(provider, model)) as? NSNumber {
            let rate = number.doubleValue
            if rate.isFinite, rate >= 0 { return rate }
        }
        switch (provider, model) {
        case (.elevenLabs, "eleven_multilingual_v2"), (.elevenLabs, "eleven_v3"): return 0.08 / 1000
        case (.elevenLabs, "eleven_flash_v2_5"): return 0.04 / 1000
        case (.openAI, "gpt-transcribe"): return 0.0045 / 60
        case (.openAI, "gpt-4o-transcribe"), (.openAI, "gpt-4o-transcribe-diarize"), (.openAI, "whisper-1"): return 0.006 / 60
        case (.openAI, "gpt-4o-mini-transcribe"): return 0.003 / 60
        default: return nil
        }
    }

    static func key(_ provider: UsageProvider, _ model: String) -> String { "usage.rate.\(provider.rawValue).\(model)" }

    static func formatUSD(_ amount: Double) -> String {
        if amount > 0, amount < 0.0001 { return "<$0.0001" }
        return String(format: amount < 1 && amount > 0 ? "$%.4f" : "$%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
    }
}

struct UsageBucket: Codable {
    var day: Date
    var provider: UsageProvider
    var model: String
    var requests = 0
    var units = 0.0 // ElevenLabs: Unicode scalars submitted; OpenAI: audio seconds.
    var estimatedUSD = 0.0
    var unpricedRequests = 0
    var unconfirmedRequests = 0
    var unconfirmedUSD = 0.0
    var rejectedRequests = 0
    var reportedCredits = 0.0
    var requestsWithCredits = 0
}

struct UsageTotals {
    var estimatedUSD = 0.0
    var requests = 0
    var characters = 0.0
    var audioSeconds = 0.0
    var unpricedRequests = 0
    var unconfirmedRequests = 0
    var unconfirmedUSD = 0.0
    var reportedCredits = 0.0
    var requestsWithCredits = 0

    init(buckets: [UsageBucket]) {
        for bucket in buckets {
            estimatedUSD += bucket.estimatedUSD
            requests += bucket.requests
            if bucket.provider == .elevenLabs { characters += bucket.units }
            else { audioSeconds += bucket.units }
            unpricedRequests += bucket.unpricedRequests
            unconfirmedRequests += bucket.unconfirmedRequests
            unconfirmedUSD += bucket.unconfirmedUSD
            reportedCredits += bucket.reportedCredits
            requestsWithCredits += bucket.requestsWithCredits
        }
    }
}

struct UsageSnapshot {
    let startedAt: Date
    let buckets: [UsageBucket]

    func totals(in interval: DateInterval? = nil, provider: UsageProvider? = nil) -> UsageTotals {
        UsageTotals(buckets: buckets.filter {
            (interval == nil || ($0.day >= interval!.start && $0.day < interval!.end)) &&
            (provider == nil || $0.provider == provider)
        })
    }
}

/// Persists only counters, model names, dates and estimated amounts; never text, audio or keys.
/// A request starts as unconfirmed so cancellation/process termination cannot erase possible charges.
final class UsageStore {
    static let shared = UsageStore(defaults: .standard)
    static let didChange = Notification.Name("FlowScribeUsageDidChange")
    private let defaults: UserDefaults?
    private let now: () -> Date
    private let calendar: Calendar
    private let lock = NSLock()
    private var buckets: [UsageBucket]
    private let startedAt: Date
    private struct Pending {
        let day: Date
        let provider: UsageProvider
        let model: String
        let units: Double
        let estimate: Double?
    }
    private var pending: [UUID: Pending] = [:]

    /// nil defaults creates a fully isolated in-memory store for tests.
    init(defaults: UserDefaults?, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
        startedAt = defaults?.object(forKey: "usage.startedAt") as? Date ?? now()
        buckets = defaults?.data(forKey: "usage.buckets").flatMap { try? JSONDecoder().decode([UsageBucket].self, from: $0) } ?? []
        defaults?.set(startedAt, forKey: "usage.startedAt")
    }

    func begin(provider: UsageProvider, model: String, units: Double?) -> UUID {
        lock.lock()
        let validUnits = units.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let units = validUnits ?? 0
        let day = calendar.startOfDay(for: now())
        let estimate = validUnits.flatMap { quantity in
            UsagePricing.rate(provider: provider, model: model, defaults: defaults).map { $0 * quantity }
        }
        let ticket = UUID()
        pending[ticket] = Pending(day: day, provider: provider, model: model, units: units, estimate: estimate)
        let index = bucketIndex(day: day, provider: provider, model: model)
        buckets[index].unconfirmedRequests += 1
        buckets[index].unconfirmedUSD += estimate ?? 0
        persist()
        lock.unlock()
        changed()
        return ticket
    }

    /// nil status means that billing could not be confirmed (timeout/cancellation/connection loss).
    func finish(_ ticket: UUID, status: Int?, reportedCredits: Double? = nil) {
        lock.lock()
        guard let request = pending.removeValue(forKey: ticket) else { lock.unlock(); return }
        let index = bucketIndex(day: request.day, provider: request.provider, model: request.model)
        if let status, (200..<500).contains(status) {
            buckets[index].unconfirmedRequests -= 1
            buckets[index].unconfirmedUSD = max(0, buckets[index].unconfirmedUSD - (request.estimate ?? 0))
            if (200..<300).contains(status) {
                buckets[index].requests += 1
                buckets[index].units += request.units
                buckets[index].estimatedUSD += request.estimate ?? 0
                if request.estimate == nil { buckets[index].unpricedRequests += 1 }
                if request.provider == .elevenLabs, let credits = reportedCredits, credits.isFinite, credits >= 0 {
                    buckets[index].reportedCredits += credits
                    buckets[index].requestsWithCredits += 1
                }
            } else { buckets[index].rejectedRequests += 1 }
        }
        // Unknown and server-error requests retain their possible charge, separate from confirmed use.
        persist()
        lock.unlock()
        changed()
    }

    func snapshot() -> UsageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return UsageSnapshot(startedAt: startedAt, buckets: buckets)
    }

    private func bucketIndex(day: Date, provider: UsageProvider, model: String) -> Int {
        if let index = buckets.firstIndex(where: { $0.day == day && $0.provider == provider && $0.model == model }) { return index }
        buckets.append(UsageBucket(day: day, provider: provider, model: model))
        return buckets.count - 1
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(buckets) { defaults?.set(data, forKey: "usage.buckets") }
    }

    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}
