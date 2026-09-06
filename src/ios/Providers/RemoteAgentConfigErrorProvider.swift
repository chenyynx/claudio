import Foundation

/// [Claudio 2026-09-06 G3.1] Placeholder AgentProvider for a remote-agent
/// instance whose Project Path is unconfigured.
///
/// Returns immediately with a single error event whose `errorDescription`
/// mirrors `RemoteUploadError.project_path_not_configured`. The chat UI
/// renders this as a guidance toast with a "Go to Settings" deep-link so
/// the user can fill the path without guesswork — replacing the previous
/// silent failure (empty path → prepare_file_upload dropped → generic
/// "[User attempted to attach X failed]" bubble with no actionable info).
///
/// Constructor enforces non-empty `projectPath` on `RemoteAgentProvider`
/// (precondition), so ProviderFactory MUST route empty-path instances
/// here. Skipping this guard and constructing the real provider would
/// crash on first chat turn.
final class RemoteAgentConfigErrorProvider: AgentProvider {

    var name: String { "Remote Session (unconfigured)" }
    var model: LLMModel
    var defaultMaxTokens: Int { 16_384 }

    /// Hardcoded error code surfaced to the UI. Mirrors the
    /// `RemoteUploadError.code` value so future telemetry / dashboards
    /// can grep one string for both the upload and provider paths.
    private static let errorCode = "project_path_not_configured"
    private let message: String

    init(model: LLMModel, message: String) {
        self.model = model
        self.message = message
    }

    func streamAgentMessageClamped(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let stream = AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            // No text deltas, no reasoning — single endTurn so the engine
            // doesn't hang waiting for a `result` it will never see.
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish(throwing: ProviderConfigError.projectPathMissing(message))
        }
        return stream
    }
}

/// Distinct error type so the chat layer can branch on it (vs. generic
/// server errors that mean "the agent actually ran and failed"). The
/// deep-link / toast rendering reads `errorDescription` for the user
/// message; `errorCode` is for telemetry.
enum ProviderConfigError: LocalizedError {
    case projectPathMissing(String)

    var errorCode: String {
        switch self {
        case .projectPathMissing: return "project_path_not_configured"
        }
    }

    var errorDescription: String? {
        switch self {
        case .projectPathMissing(let message): return message
        }
    }
}