import Foundation

struct PillSettings: Equatable {
    static let didChange = Notification.Name("FlowScribePillSettingsDidChange")

    enum Field: String, CaseIterable {
        case width, height, bars, speed, sensitivity

        var title: String {
            switch self {
            case .width: "Pill width"
            case .height: "Pill height"
            case .bars: "Number of bars"
            case .speed: "Scroll speed"
            case .sensitivity: "Sensitivity"
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .width: 68...240
            case .height: 28...64
            case .bars: 5...31
            case .speed: 0.5...3
            case .sensitivity: 0.5...2
            }
        }

        var defaultValue: Double {
            switch self {
            case .width: 104
            case .height: 36
            case .bars: 13
            case .speed: 1.5
            case .sensitivity: 1
            }
        }

        var defaultsKey: String { "recordingPill.\(rawValue)" }

        func formatted(_ value: Double) -> String {
            switch self {
            case .width, .height: String(format: "%.0f pt", value)
            case .bars: String(format: "%.0f", value)
            case .speed, .sensitivity: String(format: "%.1f×", value)
            }
        }

        func validated(_ value: Double) -> Double {
            guard value.isFinite else { return defaultValue }
            let clamped = min(range.upperBound, max(range.lowerBound, value))
            switch self {
            case .width, .height, .bars: return clamped.rounded()
            case .speed, .sensitivity: return (clamped * 10).rounded() / 10
            }
        }
    }

    private var values: [Field: Double] = [:]

    init(defaults: UserDefaults? = .standard) {
        for field in Field.allCases {
            let stored = defaults?.object(forKey: field.defaultsKey) as? NSNumber
            self[field] = stored?.doubleValue ?? field.defaultValue
        }
    }

    subscript(field: Field) -> Double {
        get { values[field] ?? field.defaultValue }
        set { values[field] = field.validated(newValue) }
    }

    func save(to defaults: UserDefaults = .standard) {
        for field in Field.allCases { defaults.set(self[field], forKey: field.defaultsKey) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// A time-based history: hardware buffers never dictate how fast bars scroll.
struct WaveformHistory {
    private(set) var levels: [Double] = []
    private var interval = 0.0
    private var accumulatedTime = 0.0
    private var accumulatedLevel = 0.0

    mutating func configure(_ settings: PillSettings) {
        let count = Int(settings[.bars])
        if levels.count != count {
            levels = Array((Array(repeating: 0, count: count) + levels).suffix(count))
        }
        let nextInterval = 0.04 / settings[.speed]
        if interval != nextInterval {
            interval = nextInterval
            accumulatedTime = 0
            accumulatedLevel = 0
        }
    }

    mutating func append(_ samples: [Double]) {
        guard !levels.isEmpty, interval > 0 else { return }
        for sample in samples {
            var remaining = 0.02 // Every meter sample represents exactly 20 ms of audio.
            while remaining > 0.000_000_1 {
                let duration = min(remaining, interval - accumulatedTime)
                accumulatedLevel += sample * duration
                accumulatedTime += duration
                remaining -= duration
                if accumulatedTime >= interval - 0.000_000_1 {
                    levels.removeFirst()
                    levels.append(accumulatedLevel / interval)
                    accumulatedTime = 0
                    accumulatedLevel = 0
                }
            }
        }
    }

    mutating func reset() {
        levels = Array(repeating: 0, count: levels.count)
        accumulatedTime = 0
        accumulatedLevel = 0
    }
}
