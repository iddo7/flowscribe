import Foundation

/// All document offsets are UTF-16, like macOS Accessibility and NSTextView.
struct ReadingText {
    struct Segment: Equatable {
        let range: NSRange
        let text: String
    }

    let text: String
    let segments: [Segment]
    let words: [NSRange]

    init(_ text: String, segmentLimit: Int = 700) {
        self.text = text
        let ns = text as NSString
        var segments: [Segment] = []
        var start = 0
        let limit = max(80, segmentLimit)
        // Prefer sentence/paragraph endings, but also bound unpunctuated selections.
        while start < ns.length {
            let proposed = min(ns.length, start + limit)
            var end = proposed
            if proposed < ns.length {
                let search = NSRange(location: start, length: proposed - start)
                let prefix = ns.substring(with: search)
                let regex = try! NSRegularExpression(pattern: "[.!?。！？][\\\"’”')]*\\s+|\\n+")
                let endings = regex.matches(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length))
                if let last = endings.last, NSMaxRange(last.range) >= 80 {
                    end = start + NSMaxRange(last.range)
                } else {
                    let space = ns.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: search)
                    if space.location != NSNotFound, space.location > start { end = NSMaxRange(space) }
                }
            }
            // Never cut a surrogate pair or composed character in half.
            let composed = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
            end = NSMaxRange(composed)
            let range = NSRange(location: start, length: end - start)
            segments.append(Segment(range: range, text: ns.substring(with: range)))
            start = end
        }
        self.segments = segments
        var words: [NSRange] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, range, _, _ in
            words.append(NSRange(range, in: text))
        }
        self.words = words
    }

    func segmentIndex(at offset: Int) -> Int? {
        segments.firstIndex { NSLocationInRange(offset, $0.range) }
    }

    func word(at offset: Int) -> NSRange {
        words.first { NSLocationInRange(offset, $0) } ?? NSRange(location: offset, length: 1)
    }

    static func shouldOffer(_ text: String, isLink: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isLink, trimmed.count >= 40, trimmed.count <= 100_000 else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count >= 6 else { return false }
        return !trimmed.lowercased().hasPrefix("https://") && !trimmed.lowercased().hasPrefix("http://")
    }
}

struct SpeechAlignment: Decodable {
    let characters: [String]
    let characterStartTimesSeconds: [Double]
    let characterEndTimesSeconds: [Double]

    /// Reject mismatched/normalized text instead of guessing the position of a word.
    func timeline(for text: String) -> SpeechTimeline? {
        guard characters.joined() == text,
              !characters.isEmpty,
              characters.count == characterStartTimesSeconds.count,
              characters.count == characterEndTimesSeconds.count else { return nil }
        var offsets: [Int] = []
        var offset = 0
        var lastStart = 0.0
        for i in characters.indices {
            let start = characterStartTimesSeconds[i]
            let end = characterEndTimesSeconds[i]
            guard !characters[i].isEmpty, start.isFinite, end.isFinite,
                  start >= lastStart, end >= start else { return nil }
            offsets.append(offset)
            offset += characters[i].utf16.count
            lastStart = start
        }
        return SpeechTimeline(offsets: offsets, starts: characterStartTimesSeconds)
    }
}

struct SpeechTimeline {
    let offsets: [Int]
    let starts: [Double]

    func offset(at time: Double) -> Int {
        let index = upperBound(starts, time) - 1
        return offsets[max(0, index)]
    }

    func time(at offset: Int) -> Double {
        let index = upperBound(offsets, offset) - 1
        return starts[max(0, index)]
    }

    private func upperBound<T: Comparable>(_ values: [T], _ target: T) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] <= target { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
