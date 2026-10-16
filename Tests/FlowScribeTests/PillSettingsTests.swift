import XCTest
@testable import FlowScribe

final class PillSettingsTests: XCTestCase {
    func testSettingsPersistAndRestoreDefaults() throws {
        let suite = "FlowScribeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = PillSettings(defaults: nil)
        settings[.width] = 180
        settings[.height] = 48
        settings[.bars] = 25
        settings[.speed] = 2.5
        settings[.sensitivity] = 0.7
        settings.save(to: defaults)
        XCTAssertEqual(PillSettings(defaults: defaults), settings)
        let original = PillSettings(defaults: nil)
        original.save(to: defaults)
        XCTAssertEqual(PillSettings(defaults: defaults), original)
    }

    func testCustomSettingsSurviveReopeningPreferencesWithoutBeingReplacedByDefaults() throws {
        let suite = "FlowScribeTests.\(UUID())"
        let originalStore = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { originalStore.removePersistentDomain(forName: suite) }
        var chosen = PillSettings(defaults: nil)
        chosen[.width] = 75
        chosen[.height] = 35
        chosen[.bars] = 10
        chosen[.speed] = 1.7
        chosen[.sensitivity] = 2
        chosen.save(to: originalStore)

        let reopenedStore = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(PillSettings(defaults: reopenedStore), chosen)
        _ = PillSettings(defaults: nil) // Constructing a default preview must never save defaults.
        XCTAssertEqual(PillSettings(defaults: reopenedStore), chosen)
    }

    func testInvalidStoredSettingsCannotBreakLayoutOrTiming() throws {
        let suite = "FlowScribeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-10, forKey: PillSettings.Field.width.defaultsKey)
        defaults.set(9_999, forKey: PillSettings.Field.height.defaultsKey)
        defaults.set(0, forKey: PillSettings.Field.bars.defaultsKey)
        defaults.set("invalid", forKey: PillSettings.Field.speed.defaultsKey)
        let settings = PillSettings(defaults: defaults)
        XCTAssertEqual(settings[.width], 68)
        XCTAssertEqual(settings[.height], 64)
        XCTAssertEqual(settings[.bars], 5)
        XCTAssertEqual(settings[.speed], PillSettings.Field.speed.defaultValue)
        var edited = settings
        edited[.speed] = .nan
        edited[.sensitivity] = .infinity
        XCTAssertEqual(edited[.speed], PillSettings.Field.speed.defaultValue)
        XCTAssertEqual(edited[.sensitivity], PillSettings.Field.sensitivity.defaultValue)
    }

    func testHistorySpeedControlsDurationAndPreservesDips() {
        var settings = PillSettings(defaults: nil)
        settings[.bars] = 5
        settings[.speed] = 2
        var history = WaveformHistory()
        history.configure(settings)
        history.append([0.1, 0.8, 0, 0.6, 0.2])
        for (actual, expected) in zip(history.levels, [0.1, 0.8, 0, 0.6, 0.2]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
        settings[.speed] = 1
        history.configure(settings)
        history.reset()
        history.append([0.8, 0.4])
        XCTAssertEqual(history.levels.last ?? -1, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(Array(history.levels.dropLast()), [0, 0, 0, 0])
    }

    func testHistoryIsIndependentOfCallbackSizeAtEverySpeed() {
        for speed in [0.5, 1, 1.5, 2, 3] {
            var settings = PillSettings(defaults: nil)
            settings[.speed] = speed
            let samples = (0..<100).map { Double($0 % 9) / 10 }
            var batched = WaveformHistory()
            var streamed = WaveformHistory()
            batched.configure(settings)
            streamed.configure(settings)
            batched.append(samples)
            samples.forEach { streamed.append([$0]) }
            XCTAssertEqual(batched.levels, streamed.levels)
            XCTAssertTrue(batched.levels.allSatisfy { $0.isFinite && (0...1).contains($0) })
        }
    }

    func testChangingBarCountPreservesRecentAudioAndResetClearsIt() {
        var settings = PillSettings(defaults: nil)
        settings[.bars] = 5
        settings[.speed] = 2
        var history = WaveformHistory()
        history.configure(settings)
        history.append([0.1, 0.8, 0.2])
        settings[.bars] = 7
        history.configure(settings)
        XCTAssertEqual(history.levels.count, 7)
        for (actual, expected) in zip(history.levels, [0, 0, 0, 0, 0.1, 0.8, 0.2]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
        history.reset()
        XCTAssertEqual(history.levels, Array(repeating: 0, count: 7))
    }
}
