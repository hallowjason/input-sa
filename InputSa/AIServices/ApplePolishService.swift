import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// Constrained-decoding output schema. Guided generation is the pollution fix:
/// the 3B model intermittently echoed the prompt scaffold into its plain-text
/// output (user-reported, reproduced 2026-07-15); with a @Generable schema the
/// decoder can only emit the `text` field — 0/18 scaffold echoes in the spike
/// (scratchpad/fm-quality/main5.swift) vs. frequent echoes in free-text mode.
@available(macOS 26.0, *)
@Generable
private struct PolishOutput {
    @Guide(description: "整理後的可直接使用文字，不含任何說明或標籤")
    var text: String
}
#endif

/// Fully-offline polish provider backed by Apple's on-device Foundation model
/// (macOS 26+). Its public interface mirrors `GeminiPolishService` exactly so
/// the two are swappable behind one dispatch in `InputController`.
///
/// Decisions locked in by the 2026-07-14 feasibility spike (scratchpad/fm-quality):
/// - One fresh `LanguageModelSession` per request. The context window is only
///   ~4096 tokens; reusing a session accumulates transcript history and trips
///   `exceededContextWindowSize` within a few dictations.
/// - No `instructions:` argument. Splitting the system prompt from the user text
///   broke the injection defense in the spike (the "please translate this" test
///   started getting executed). The whole `mode.systemPrompt(transcript:)` goes
///   into `respond(to:)` — the one format that stayed stable across four rounds.
/// - Streaming snapshots are cumulative: each `snapshot.content` is the full text
///   so far, fed straight to `onPartial` for the HUD live preview, matching how
///   the Gemini SSE path accumulates.
///
/// The whole FoundationModels surface is gated so the app still links and launches
/// on macOS 12 (the build target): `import` is `canImport`-wrapped, every model
/// call is `@available(macOS 26.0, *)` / `if #available`, and the framework is
/// weak-linked automatically because it sits above the deployment target.
final class ApplePolishService {

    static let shared = ApplePolishService()

    /// Whether the on-device model can serve a request right now, plus a
    /// plain-language Chinese reason when it can't (shown in Preferences).
    struct Availability {
        let isAvailable: Bool
        let reason: String   // "" when available
    }

    static var availabilityStatus: Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return Availability(isAvailable: true, reason: "")
            case .unavailable(let reason):
                return Availability(isAvailable: false, reason: describe(reason))
            }
        } else {
            return Availability(isAvailable: false,
                reason: "需要 macOS 26 以上系統才能使用 Apple 本地潤飾")
        }
        #else
        return Availability(isAvailable: false,
            reason: "此版本未內建 Apple 本地潤飾")
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "這台裝置不支援 Apple Intelligence（需 Apple 晶片機型）"
        case .appleIntelligenceNotEnabled:
            return "尚未開啟 Apple Intelligence，請到系統設定開啟後再試"
        case .modelNotReady:
            return "模型正在下載或準備中，請稍後再試"
        @unknown default:
            return "Apple 本地模型目前無法使用"
        }
    }
    #endif

    // MARK: - Prewarm
    /// Kept alive so the prewarmed assets aren't dropped before the real request.
    private var warmSession: Any?

    /// Wake the on-device model while the user is still speaking, so the first
    /// polish after launch doesn't pay the model-load latency on top of
    /// generation. Cheap and idempotent — safe to call on every key-down.
    func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return }
            let session = LanguageModelSession()
            session.prewarm()
            warmSession = session
        }
        #endif
    }

    // MARK: - Enhance
    /// `onPartial` receives the accumulated text so far, on the main thread —
    /// same contract as `GeminiPolishService.enhance`.
    func enhance(
        text: String,
        mode: TranscriptionMode,
        onPartial: ((String) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // Guided generation is near-atomic (2 snapshots for a whole sentence),
            // so there is nothing useful to stream — `onPartial` is intentionally
            // unused and the HUD keeps its static "AI 潤飾中（本地）…" state.
            _ = onPartial
            let prompt = mode.systemPrompt(transcript: text)
            Task {
                do {
                    let clean = try await Self.generateClean(prompt: prompt,
                                                             inputLength: text.count)
                    DispatchQueue.main.async { completion(.success(clean)) }
                } catch {
                    let msg = Self.friendlyError(error)
                    DispatchQueue.main.async {
                        completion(.failure(NSError(domain: "InputSa", code: 20,
                            userInfo: [NSLocalizedDescriptionKey: msg])))
                    }
                }
            }
            return
        }
        #endif
        // Unsupported system or SDK: fail with the availability reason so the
        // caller runs its existing raw-transcript fallback (never a silent cloud call).
        DispatchQueue.main.async {
            completion(.failure(NSError(domain: "InputSa", code: 21,
                userInfo: [NSLocalizedDescriptionKey: Self.availabilityStatus.reason])))
        }
    }

    // MARK: - Polish selected text (manual trigger)
    func polish(
        selectedText: String,
        mode: TranscriptionMode,
        onPartial: ((String) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        enhance(text: selectedText, mode: mode, onPartial: onPartial, completion: completion)
    }

    // MARK: - Clean generation (constrained decode + safety net)
    #if canImport(FoundationModels)
    /// Prompt-scaffold fingerprints. Guided generation makes echoes rare but a
    /// paraphrased rule line still slipped through once in the spike, so any
    /// output containing one of these is discarded (retry once, then fail into
    /// the caller's raw-transcript fallback). These phrases cannot plausibly
    /// occur in dictated speech.
    private static let scaffoldFingerprints = [
        "<transcript", "</transcript", "領域詞彙表", "口述文字編輯", "詞彙表規則",
        "整段語意", "逐字保守替換", "口頭禪贅字", "整理後的文字", "待整理的資料",
        "風格指令", "待處理的資料",
    ]

    @available(macOS 26.0, *)
    private static func generateClean(prompt: String, inputLength: Int) async throws -> String {
        // Cap the response: the model occasionally runs away (observed: one 80s
        // generation that filled the whole 4096-token window). Polish output is
        // never longer than its input by much, so 1024 tokens is generous; a
        // runaway now gets cut off in seconds and rejected below instead.
        let options = GenerationOptions(maximumResponseTokens: 1024)
        // A truncated runaway can also slip past the fingerprints, so anything
        // implausibly longer than the input is rejected too (custom styles may
        // expand text, hence the loose 3x bound).
        let maxPlausible = max(inputLength * 3, inputLength + 200)
        for attempt in 1...2 {
            // Fresh session per attempt (see class doc): no carried context.
            let session = LanguageModelSession()
            let raw = try await session.respond(to: prompt, generating: PolishOutput.self,
                                                options: options)
                .content.text
            let clean = sanitize(raw)
            if !clean.isEmpty && clean.count <= maxPlausible
                && !scaffoldFingerprints.contains(where: { clean.contains($0) }) {
                return clean
            }
            inputSaLog("apple polish attempt \(attempt) rejected (empty/overlong/scaffold echo, \(clean.count) chars)")
        }
        throw NSError(domain: "InputSa", code: 23,
            userInfo: [NSLocalizedDescriptionKey: "Apple 本地模型連續輸出不穩定內容，已改回原稿"])
    }

    /// Strip artifacts the model occasionally wraps around an otherwise good
    /// result, so borderline outputs survive instead of tripping the fingerprints.
    private static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["<transcript>", "</transcript>"] {
            s = s.replacingOccurrences(of: tag, with: "")
        }
        for prefix in ["整理後的文字：", "輸出："] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    // MARK: - Error mapping
    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func friendlyError(_ error: Error) -> String {
        if let gen = error as? LanguageModelSession.GenerationError {
            switch gen {
            case .exceededContextWindowSize:
                return "這段文字太長，超過 Apple 本地模型上限（約 4096 tokens），請分段後再試或改用 Gemini"
            case .guardrailViolation:
                return "內容被 Apple 安全機制攔下，未能潤飾"
            case .assetsUnavailable:
                return "Apple 本地模型尚未就緒（下載中或未安裝）"
            case .rateLimited:
                return "Apple 本地模型忙碌中，請稍後再試"
            default:
                return "Apple 本地潤飾失敗：\(gen.localizedDescription)"
            }
        }
        return "Apple 本地潤飾失敗：\(error.localizedDescription)"
    }
    #endif
}
