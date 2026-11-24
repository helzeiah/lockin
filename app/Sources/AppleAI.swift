import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The AI planner on Apple Intelligence: Apple's on-device model (macOS 26+, Apple silicon). Free, private, offline,
/// no account or key. The helper script still writes the prompt and checks the answer; only the model runs here.
enum AppleAI {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func failure(_ text: String) -> Failure { Failure(errorDescription: text) }

    /// Can Apple Intelligence run on this Mac right now, and if not, why (shown in Settings).
    static var status: (ok: Bool, text: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return (true, "Ready. Runs on this Mac, free, nothing leaves it.")
            case .unavailable(.deviceNotEligible): return (false, "This Mac can't run Apple Intelligence (it needs Apple silicon).")
            case .unavailable(.appleIntelligenceNotEnabled): return (false, "Turn on Apple Intelligence in System Settings first.")
            case .unavailable(.modelNotReady): return (false, "Apple Intelligence is still getting ready. Try again in a bit.")
            default: return (false, "Apple Intelligence isn't available right now.")
            }
        }
        #endif
        return (false, "Needs macOS 26 or later.")
    }

    /// The plan as JSON ({"items": [...], "reply": "..."}), generated to a fixed structure so it always parses.
    static func plan(prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard status.ok else { throw failure(status.text) }
            let item = DynamicGenerationSchema(name: "Item", properties: [
                .init(name: "ref", description: "the existing item's ref, or \"new\"", schema: .init(type: String.self)),
                .init(name: "task", schema: .init(type: String.self)),
                .init(name: "minutes", schema: .init(type: Int.self)),
                .init(name: "start", description: "24h HH:MM start, or empty", schema: .init(type: String.self)),
                .init(name: "done", schema: .init(type: Bool.self)),
                .init(name: "why", description: "at most 8 words", schema: .init(type: String.self)),
            ])
            let root = DynamicGenerationSchema(name: "Plan", properties: [
                .init(name: "items", schema: .init(arrayOf: item)),
                .init(name: "reply", description: "one short sentence saying what changed", schema: .init(type: String.self)),
            ])
            let schema = try GenerationSchema(root: root, dependencies: [])
            let session = LanguageModelSession(instructions: "You are the day planner inside a focus app. Follow the rules in the request exactly.")
            let answer = try await session.respond(to: prompt, schema: schema)
            return answer.content.jsonString
        }
        #endif
        throw failure(status.text)
    }
}
