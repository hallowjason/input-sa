import Foundation

/// Simplified → Traditional (Taiwan, with phrases) converter.
///
/// Loads the pre-merged OpenCC `s2twp` dictionary (`opencc/s2twp_dict.json`) and
/// applies its stages in order. Each stage performs a greedy longest-match scan:
/// at every position the longest matching key wins, the match is replaced, and the
/// cursor advances past it; otherwise a single character is copied verbatim.
///
/// Stage order (per OpenCC s2twp): STPhrases → STCharacters → TWPhrases → TWVariants.
final class OpenCCConverter {

    private struct Stage {
        let map: [String: String]
        let maxKeyLength: Int
    }

    private let stages: [Stage]

    /// Shared instance loaded from the app bundle. Falls back to an identity
    /// converter (returns input unchanged) if the dictionary is missing — local
    /// transcription should never crash just because the dict failed to load.
    static let shared: OpenCCConverter = {
        if let url = Bundle.main.url(forResource: "s2twp_dict", withExtension: "json", subdirectory: "opencc")
            ?? Bundle.main.url(forResource: "s2twp_dict", withExtension: "json"),
           let converter = try? OpenCCConverter(dictionaryURL: url) {
            return converter
        }
        NSLog("[InputSa] OpenCCConverter: s2twp_dict.json not found — conversion disabled (identity)")
        return OpenCCConverter(stages: [])
    }()

    // MARK: - Init

    /// Designated initializer. `stages` are applied in array order.
    init(stages: [[String: String]]) {
        self.stages = stages.map { map in
            Stage(map: map, maxKeyLength: map.keys.map { $0.count }.max() ?? 1)
        }
    }

    convenience init(dictionaryData data: Data) throws {
        let decoded = try JSONDecoder().decode(DictionaryFile.self, from: data)
        self.init(stages: decoded.stages.map { $0.map })
    }

    convenience init(dictionaryURL url: URL) throws {
        try self.init(dictionaryData: Data(contentsOf: url))
    }

    // MARK: - Conversion

    func convert(_ simplified: String) -> String {
        var text = simplified
        for stage in stages {
            text = Self.applyStage(text, stage: stage)
        }
        return text
    }

    /// Greedy longest-match scan over Characters for a single stage.
    private static func applyStage(_ input: String, stage: Stage) -> String {
        guard !stage.map.isEmpty else { return input }
        let chars = Array(input)
        let n = chars.count
        var result = ""
        result.reserveCapacity(n)

        var i = 0
        while i < n {
            let maxLen = min(stage.maxKeyLength, n - i)
            var matched = false
            // Try longest possible key first.
            var len = maxLen
            while len >= 1 {
                let candidate = String(chars[i..<(i + len)])
                if let replacement = stage.map[candidate] {
                    result += replacement
                    i += len
                    matched = true
                    break
                }
                len -= 1
            }
            if !matched {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }

    // MARK: - JSON model

    private struct DictionaryFile: Decodable {
        struct StageJSON: Decodable {
            let name: String
            let map: [String: String]
        }
        let stages: [StageJSON]
    }
}
