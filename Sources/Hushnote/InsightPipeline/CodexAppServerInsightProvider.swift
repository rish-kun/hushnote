import Foundation

public struct CodexLoginChallenge: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case browser(URL)
        case deviceCode(verificationURL: URL, userCode: String)
    }

    public let loginID: String
    public let mode: Mode

    public init(loginID: String, mode: Mode) {
        self.loginID = loginID
        self.mode = mode
    }
}

public actor CodexAppServerInsightProvider: InsightProvider {
    public nonisolated let descriptor = InsightProviderDescriptor(
        id: "chatgpt-codex",
        displayName: "ChatGPT (via Codex)",
        kind: .codexAppServer,
        sendsTranscriptOffDevice: true
    )

    private let transport: any CodexAppServerTransport
    private let model: String?
    private var initialized = false
    private var nextID = 1
    private var messagePump: Task<Void, Never>?
    private var inbox: CodexMessageInbox?

    public init(
        model: String? = nil,
        transport: any CodexAppServerTransport = ProcessCodexAppServerTransport()
    ) {
        self.model = model
        self.transport = transport
    }

    public func healthCheck() async -> InsightProviderHealth {
        do {
            try await ensureInitialized()
            let response = try await call(method: "account/read", params: .object(["refreshToken": .bool(false)]))
            guard let account = response["result"]?["account"], account != .null else {
                return .unavailable("ChatGPT account not connected")
            }
            return .available
        } catch {
            return .unavailable("Codex App Server unavailable")
        }
    }

    public func beginBrowserLogin() async throws -> CodexLoginChallenge {
        try await ensureInitialized()
        let response = try await call(
            method: "account/login/start",
            params: .object([
                "type": .string("chatgpt"),
                "useHostedLoginSuccessPage": .bool(true),
                "appBrand": .string("chatgpt")
            ])
        )
        guard let result = response["result"],
              let loginID = result["loginId"]?.stringValue,
              let authURL = result["authUrl"]?.stringValue.flatMap(URL.init(string:)) else {
            throw InsightProviderError.malformedResponse
        }
        return CodexLoginChallenge(loginID: loginID, mode: .browser(authURL))
    }

    public func beginDeviceCodeLogin() async throws -> CodexLoginChallenge {
        try await ensureInitialized()
        let response = try await call(
            method: "account/login/start",
            params: .object(["type": .string("chatgptDeviceCode")])
        )
        guard let result = response["result"],
              let loginID = result["loginId"]?.stringValue,
              let code = result["userCode"]?.stringValue,
              let url = result["verificationUrl"]?.stringValue.flatMap(URL.init(string:)) else {
            throw InsightProviderError.malformedResponse
        }
        return CodexLoginChallenge(
            loginID: loginID,
            mode: .deviceCode(verificationURL: url, userCode: code)
        )
    }

    public func waitForLogin(loginID: String) async throws {
        while let message = try await nextMessage() {
            guard message["method"]?.stringValue == "account/login/completed",
                  message["params"]?["loginId"]?.stringValue == loginID else { continue }
            if message["params"]?["success"] == .bool(true) { return }
            throw InsightProviderError.rpcError(
                code: -1,
                message: message["params"]?["error"]?.stringValue ?? "Login failed"
            )
        }
        throw InsightProviderError.transportFailure
    }

    public func logout() async throws {
        try await ensureInitialized()
        _ = try await call(method: "account/logout", params: .object([:]))
    }

    /// Every tool Codex can reach, switched off.
    ///
    /// These are the same keys the verified `codex exec` lockdown uses
    /// (`--disable` is `features.<name>=false`), expressed as the `config`
    /// override object `thread/start` accepts.
    private static let toollessConfig = JSONValue.object([
        "features": .object([
            "shell_tool": .bool(false),
            "unified_exec": .bool(false),
            "view_image": .bool(false)
        ]),
        "tools": .object(["web_search": .bool(false)]),
        // Project docs are read from the working directory before the turn even
        // starts, and they are billed on every summary.
        "project_doc_max_bytes": .number(0),
        "include_environment_context": .bool(false)
    ])

    public func complete(_ request: InsightProviderRequest) async throws -> String {
        try await ensureInitialized()
        // A turn is an agent, not a completion. It gets an empty directory to
        // stand in, because `read-only` in Codex means "read anything on the
        // filesystem, write nothing" and `approvalPolicy: never` means it does
        // so without asking.
        let sandbox = try AgentSandboxDirectory.make(label: "codex")
        defer { sandbox.remove() }

        var threadParameters: [String: JSONValue] = [
            "ephemeral": .bool(true),
            "approvalPolicy": .string("never"),
            // The protocol spells the thread-level sandbox mode "read-only";
            // "readOnly" is the turn-level policy tag and is rejected here.
            "sandbox": .string("read-only"),
            "serviceName": .string("hushnote"),
            "cwd": .string(sandbox.path),
            // The instruction channel. What Hushnote wants done goes here and
            // only here, so that the transcript below cannot rewrite it.
            "developerInstructions": .string(request.systemPrompt),
            "config": Self.toollessConfig
        ]
        if let model { threadParameters["model"] = .string(model) }
        let threadResponse = try await call(
            method: "thread/start",
            params: .object(threadParameters)
        )
        guard let threadID = threadResponse["result"]?["thread"]?["id"]?.stringValue else {
            throw InsightProviderError.malformedResponse
        }

        // The data channel. Anyone who can speak in a meeting writes this.
        let turnID = nextRequestID()
        try await transport.send(.object([
            "method": .string("turn/start"),
            "id": .number(Double(turnID)),
            "params": .object([
                "threadId": .string(threadID),
                "input": .array([.object([
                    "type": .string("text"),
                    "text": .string(request.userPrompt)
                ])]),
                "approvalPolicy": .string("never"),
                "sandboxPolicy": .object(["type": .string("readOnly")]),
                "cwd": .string(sandbox.path),
                "outputSchema": request.outputSchema
            ])
        ]))
        let turnResponse = try await response(for: turnID)
        guard let startedTurnID = turnResponse["result"]?["turn"]?["id"]?.stringValue else {
            throw InsightProviderError.malformedResponse
        }

        var finalText: String?
        while let message = try await nextMessage() {
            if message["method"]?.stringValue == "item/completed",
               message["params"]?["item"]?["type"]?.stringValue == "agentMessage",
               let text = message["params"]?["item"]?["text"]?.stringValue {
                finalText = text
            }
            if message["method"]?.stringValue == "turn/completed",
               message["params"]?["turn"]?["id"]?.stringValue == startedTurnID {
                guard message["params"]?["turn"]?["status"]?.stringValue == "completed" else {
                    throw InsightProviderError.rpcError(
                        code: -1,
                        message: message["params"]?["turn"]?["error"]?["message"]?.stringValue
                            ?? "Codex turn did not complete"
                    )
                }
                break
            }
        }
        guard let finalText else { throw InsightProviderError.malformedResponse }
        return finalText
    }

    public func shutdown() async {
        messagePump?.cancel()
        messagePump = nil
        await inbox?.finish()
        inbox = nil
        await transport.stop()
        initialized = false
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        try await transport.start()
        let stream = await transport.messages()
        let inbox = CodexMessageInbox()
        self.inbox = inbox
        messagePump = Task {
            do {
                for try await message in stream {
                    try Task.checkCancellation()
                    await inbox.enqueue(message)
                }
                await inbox.finish()
            } catch is CancellationError {
                await inbox.finish()
            } catch {
                await inbox.fail()
            }
        }
        let requestID = nextRequestID()
        try await transport.send(.object([
            "method": .string("initialize"),
            "id": .number(Double(requestID)),
            "params": .object([
                "clientInfo": .object([
                    "name": .string("hushnote"),
                    "title": .string("Hushnote"),
                    "version": .string("0.1.0")
                ])
            ])
        ]))
        _ = try await response(for: requestID)
        try await transport.send(.object([
            "method": .string("initialized"),
            "params": .object([:])
        ]))
        initialized = true
    }

    private func call(method: String, params: JSONValue) async throws -> JSONValue {
        let requestID = nextRequestID()
        try await transport.send(.object([
            "method": .string(method),
            "id": .number(Double(requestID)),
            "params": params
        ]))
        return try await response(for: requestID)
    }

    private func response(for id: Int) async throws -> JSONValue {
        while let message = try await nextMessage() {
            guard message["id"] == .number(Double(id)) else { continue }
            if let error = message["error"] {
                let code: Int
                if case .number(let value) = error["code"] { code = Int(value) } else { code = -1 }
                throw InsightProviderError.rpcError(
                    code: code,
                    message: error["message"]?.stringValue ?? "Unknown JSON-RPC error"
                )
            }
            return message
        }
        throw InsightProviderError.transportFailure
    }

    private func nextMessage() async throws -> JSONValue? {
        guard let inbox else { return nil }
        return try await inbox.next()
    }

    private func nextRequestID() -> Int {
        defer { nextID += 1 }
        return nextID
    }
}

private actor CodexMessageInbox {
    private var buffered: [JSONValue] = []
    private var waiters: [CheckedContinuation<JSONValue?, any Error>] = []
    private var terminalError: InsightProviderError?
    private var isFinished = false

    func enqueue(_ message: JSONValue) {
        guard !isFinished else { return }
        if waiters.isEmpty {
            buffered.append(message)
        } else {
            waiters.removeFirst().resume(returning: message)
        }
    }

    func next() async throws -> JSONValue? {
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }
        if let terminalError { throw terminalError }
        if isFinished { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish() {
        complete(with: nil)
    }

    func fail() {
        complete(with: .transportFailure)
    }

    private func complete(with error: InsightProviderError?) {
        guard !isFinished else { return }
        terminalError = error
        isFinished = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: nil)
            }
        }
    }
}
