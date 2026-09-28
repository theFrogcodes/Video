import Foundation

/// Cleans Japanese speech-recognition output before it is translated.
///
/// Speech recognisers fed music or silence often "hallucinate" stock phrases
/// learned from video subtitles (e.g. ご視聴ありがとうございました, "thanks for
/// watching"). Dubbing those would be jarring, so they are discarded.
public enum TranscriptFilter {
    /// Phrases that, when they make up the whole transcript, are almost always
    /// recogniser artefacts rather than dialogue. Compared after normalisation.
    static let hallucinations: Set<String> = [
        "ご視聴ありがとうございました",
        "ご視聴ありがとうございます",
        "ご清聴ありがとうございました",
        "最後までご視聴いただきありがとうございました",
        "チャンネル登録お願いします",
        "チャンネル登録をお願いします",
        "チャンネル登録よろしくお願いします",
        "おやすみなさいご視聴ありがとうございました",
        "thankyouforwatching",
        "thanksforwatching",
    ]

    /// Fragments that mark a caption/credit line wherever they appear.
    static let captionMarkers = ["字幕", "ご視聴ありがとう", "チャンネル登録", "subtitlesby", "subtitledby"]

    /// Returns the cleaned transcript, or nil when nothing dub-worthy remains.
    public static func clean(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Drop sung passages and bracketed annotations such as （笑） or [音楽].
        text = text.replacingOccurrences(of: "♪[^♪]*♪", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "[♪♫]", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "[（(\\[【〔][^）)\\]】〕]{0,12}[）)\\]】〕]", with: " ", options: .regularExpression)
        // Collapse stuck-recogniser loops like "あああああああああ".
        text = text.replacingOccurrences(of: "(.)\\1{5,}", with: "$1$1$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let normalized = normalize(text)
        guard normalized.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        if hallucinations.contains(normalized) { return nil }
        if captionMarkers.contains(where: { normalized.contains($0) }) { return nil }
        return text
    }

    /// Lower-cased with punctuation, symbols and whitespace removed.
    static func normalize(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.filter { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        return String(String.UnicodeScalarView(kept))
    }
}
