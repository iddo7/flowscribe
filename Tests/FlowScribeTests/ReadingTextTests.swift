import XCTest
@testable import FlowScribe

final class ReadingTextTests: XCTestCase {
    func testSegmentsPreserveExactTextAndUTF16Offsets() {
        let text = String(repeating: "Bonjour 👩🏽‍💻! Voici une phrase avec café et e\u{301}motion.\n", count: 70)
        let reading = ReadingText(text, segmentLimit: 180)
        XCTAssertGreaterThan(reading.segments.count, 1)
        XCTAssertEqual(reading.segments.map(\.text).joined(), text)
        var offset = 0
        for segment in reading.segments {
            XCTAssertEqual(segment.range.location, offset)
            XCTAssertEqual(segment.range.length, segment.text.utf16.count)
            XCTAssertFalse(segment.text.contains("\u{FFFD}"))
            offset = NSMaxRange(segment.range)
        }
        XCTAssertEqual(offset, text.utf16.count)
    }

    func testUnpunctuatedTextAndLongUnicodeWordsAreBounded() {
        let text = String(repeating: "👩🏽‍💻é", count: 300)
        let reading = ReadingText(text, segmentLimit: 80)
        XCTAssertEqual(reading.segments.map(\.text).joined(), text)
        XCTAssertTrue(reading.segments.allSatisfy { $0.range.length < 100 })
    }

    func testSeekLocatesCorrectRepeatedWordAndSegment() {
        let text = String(repeating: "Voici le même mot répété dans une longue phrase. ", count: 40)
        let reading = ReadingText(text, segmentLimit: 140)
        let target = (text as NSString).range(of: "répété", options: .backwards)
        let index = reading.segmentIndex(at: target.location)!
        XCTAssertGreaterThan(index, 0)
        XCTAssertEqual(reading.word(at: target.location + 2), target)
        XCTAssertTrue(NSLocationInRange(target.location, reading.segments[index].range))
        XCTAssertNil(reading.segmentIndex(at: text.utf16.count))
        XCTAssertNil(reading.segmentIndex(at: -1))
    }

    func testSelectionButtonIgnoresShortTextLinksAndOversizedSelections() {
        let paragraph = "Une sélection assez longue pour afficher un bouton de lecture très discret."
        XCTAssertTrue(ReadingText.shouldOffer(paragraph, isLink: false))
        XCTAssertFalse(ReadingText.shouldOffer(paragraph, isLink: true))
        XCTAssertFalse(ReadingText.shouldOffer("Un petit mot", isLink: false))
        XCTAssertFalse(ReadingText.shouldOffer("https://example.com/une-adresse-de-page-assez-longue-et-sans-espaces", isLink: false))
        XCTAssertFalse(ReadingText.shouldOffer(String(repeating: paragraph, count: 2000), isLink: false))
    }

    func testAlignmentUsesUTF16AndSupportsForwardAndBackwardSeeking() {
        let alignment = SpeechAlignment(characters: ["A", "👋", "é", " ", "B"],
                                        characterStartTimesSeconds: [0, 0.2, 0.5, 0.7, 1],
                                        characterEndTimesSeconds: [0.2, 0.5, 0.7, 1, 1.2])
        let timeline = alignment.timeline(for: "A👋é B")!
        XCTAssertEqual(timeline.offset(at: 0.6), 3)
        XCTAssertEqual(timeline.time(at: 5), 1)
        XCTAssertEqual(timeline.time(at: 1), 0.2)
        XCTAssertEqual(timeline.offset(at: -1), 0)
        XCTAssertEqual(timeline.offset(at: 100), 5)
        XCTAssertEqual(timeline.time(at: 2), 0.2)
    }

    func testMalformedOrNormalizedAlignmentNeverGuessesWordPositions() {
        XCTAssertNil(SpeechAlignment(characters: ["1"], characterStartTimesSeconds: [0],
                                    characterEndTimesSeconds: [1]).timeline(for: "one"))
        XCTAssertNil(SpeechAlignment(characters: ["A"], characterStartTimesSeconds: [],
                                    characterEndTimesSeconds: [1]).timeline(for: "A"))
        XCTAssertNil(SpeechAlignment(characters: ["A"], characterStartTimesSeconds: [.nan],
                                    characterEndTimesSeconds: [1]).timeline(for: "A"))
        XCTAssertNil(SpeechAlignment(characters: ["A", "B"], characterStartTimesSeconds: [1, 0],
                                    characterEndTimesSeconds: [2, 1]).timeline(for: "AB"))
        XCTAssertNil(SpeechAlignment(characters: [], characterStartTimesSeconds: [],
                                    characterEndTimesSeconds: []).timeline(for: ""))
    }

    func testReaderPreferencesPersistSeparatelyFromDictationAndClampInvalidSpeed() {
        let name = "FlowScribe.ReaderTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("existing-input", forKey: "audioInputUID")
        var settings = ReaderSettings.load(defaults: defaults)
        settings.voiceID = "customVoice"
        settings.model = .expressive
        settings.speed = 1.5
        settings.offersSelection = false
        settings.save(defaults: defaults)
        let loaded = ReaderSettings.load(defaults: defaults)
        XCTAssertEqual(loaded.voiceID, "customVoice")
        XCTAssertEqual(loaded.model, .expressive)
        XCTAssertEqual(loaded.speed, 1.5)
        XCTAssertFalse(loaded.offersSelection)
        XCTAssertEqual(defaults.string(forKey: "audioInputUID"), "existing-input")
        defaults.set(100, forKey: "reader.speed")
        XCTAssertEqual(ReaderSettings.load(defaults: defaults).speed, 1)
    }

    func testElevenLabsEnvironmentKeyDoesNotUseOpenAIKey() {
        XCTAssertNil(ElevenLabsKeyStore.resolveKey(environment: ["OPENAI_API_KEY": "unrelated"], keychainReader: { nil }))
        XCTAssertEqual(ElevenLabsKeyStore.resolveKey(environment: ["ELEVENLABS_API_KEY": " key "],
                                                    keychainReader: { XCTFail("Must use env key"); return nil }), "key")
        XCTAssertEqual(ElevenLabsKeyStore.resolveKey(environment: ["ELEVENLABS_API_KEY": " "],
                                                    keychainReader: { "saved" }), "saved")
        XCTAssertNotEqual(ElevenLabsKeyStore.account, APIKeyStore.keychainAccount)
    }
}
