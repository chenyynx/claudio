import Foundation

/// WebSocket client for a CC Pocket Bridge Server.
///
/// Owns the connection lifecycle (connect / send / receive / disconnect)
/// and exposes the server message stream to the provider layer.
/// Reconnect strategy is deliberately basic in M1 (connect once, fail with
/// an error) — full reconnect/queueing lands in M4.
final class CCPocketClient: @unchecked Sendable {

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private(set) var state: State = .idle

    private let baseURL: URL
    private let token: String
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    /// Single active consumer of the server message stream. The provider
    /// installs a handler per turn; a turn ends when the handler sees a
    /// `result` (or error). Sequential turns are the M1 contract.
    var onMessage: ((CCPocketProtocol.ServerMessage) -> Void)?

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    // MARK: - Connection

    /// Connect to the Bridge. `projectPath` is the working directory the
    /// Bridge should open the agent session in.
    func connect(projectPath: String, provider: String = "claude") async throws {
        guard state == .idle else { return }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else {
            throw CCPocketError.invalidURL
        }

        state = .connecting
        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: url)
        task = wsTask
        wsTask.resume()
        state = .connected

        // Announce client capabilities first; Bridge replies with history/state.
        let capabilities = CCPocketProtocol.ClientCapabilities()
        try await send(CCPocketProtocol.encode(capabilities))

        // Start an agent session on this project path.
        let start = CCPocketProtocol.StartRequest(
            projectPath: projectPath,
            provider: provider,
            requestId: UUID().uuidString
        )
        try await send(CCPocketProtocol.encode(start))

        startReceiveLoop()
    }

    /// Continuously receive server messages and dispatch to the active handler.
    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await self.task?.receive()
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let serverMessage = CCPocketProtocol.decodeServerMessage(data) {
                            self.onMessage?(serverMessage)
                        }
                    case .data(let data):
                        if let serverMessage = CCPocketProtocol.decodeServerMessage(data) {
                            self.onMessage?(serverMessage)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    self.state = .failed(error.localizedDescription)
                    return
                }
            }
        }
    }

    // MARK: - Sending

    func sendInput(_ text: String, sessionId: String? = nil) async throws {
        let input = CCPocketProtocol.InputRequest(
            text: text,
            sessionId: sessionId,
            clientMessageId: UUID().uuidString
        )
        try await send(CCPocketProtocol.encode(input))
    }

    private func send(_ string: String) async throws {
        guard let task else { throw CCPocketError.notConnected }
        try await task.send(.string(string))
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onMessage = nil
        state = .idle
    }

    deinit {
        disconnect()
    }
}

enum CCPocketError: LocalizedError {
    case invalidURL
    case notConnected
    case sessionNotStarted

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Bridge URL"
        case .notConnected: return "Not connected to Bridge"
        case .sessionNotStarted: return "Agent session has not started"
        }
    }
}
