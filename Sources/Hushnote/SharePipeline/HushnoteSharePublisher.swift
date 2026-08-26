import Foundation

/// The real network boundary. Everything above it talks to `SharePublishing`,
/// so nothing above it has to be tested against a server.
///
/// It takes the device token as a value rather than reading the Keychain: this
/// type should be constructible in a test with a token that never existed, and
/// deciding *which* credential a request carries is the coordinator's business.
struct HushnoteSharePublisher: SharePublishing {
    private let origin: URL
    private let deviceToken: String
    private let httpClient: any HTTPClient

    init(origin: URL, deviceToken: String, httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.origin = origin
        self.deviceToken = deviceToken
        self.httpClient = httpClient
    }

    func create(payload: SharePayload, password: String?) async throws -> String {
        guard !payload.includes.isEmpty else { throw ShareError.nothingSelected }
        let body = try encode(
            CreateBody(
                includes: payload.includes,
                payload: payload,
                password: password
            )
        )
        let data = try await send(
            method: "POST",
            url: ShareLinkPolicy.createEndpoint(origin: origin),
            body: body
        )
        // An id this app cannot form a link from is a broken response, not a
        // share. Failing here is what keeps an unusable id out of the database.
        guard let id = decodedShareID(data), ShareLinkPolicy.isValidShareID(id) else {
            throw ShareError.server(status: 200, message: "The share service returned no usable link.")
        }
        return id
    }

    func update(shareID: String, payload: SharePayload) async throws {
        guard !payload.includes.isEmpty else { throw ShareError.nothingSelected }
        _ = try await send(
            method: "PUT",
            url: try endpoint(shareID),
            body: try encode(UpdateBody(includes: payload.includes, payload: payload))
        )
    }

    func setPassword(shareID: String, password: String?) async throws {
        _ = try await send(
            method: "PUT",
            url: try passwordEndpoint(shareID),
            body: try encode(PasswordBody(password: password))
        )
    }

    func revoke(shareID: String) async throws {
        do {
            _ = try await send(method: "DELETE", url: try endpoint(shareID), body: nil)
        } catch ShareError.notFound, ShareError.revoked {
            // Already gone is the outcome revoking asked for. Throwing here
            // would block the caller's next step — deleting the meeting — on a
            // link that no longer exists.
            return
        }
    }

    private func endpoint(_ shareID: String) throws -> URL {
        guard let url = ShareLinkPolicy.shareEndpoint(shareID: shareID, origin: origin) else {
            throw ShareError.notFound
        }
        return url
    }

    private func passwordEndpoint(_ shareID: String) throws -> URL {
        guard let url = ShareLinkPolicy.passwordEndpoint(shareID: shareID, origin: origin) else {
            throw ShareError.notFound
        }
        return url
    }

    private func send(method: String, url: URL, body: Data?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            // A transport failure is not a server verdict, and must not be read
            // as one: it leaves the previously published version untouched.
            throw ShareError.transport(error.localizedDescription)
        }
        if let failure = Self.failure(status: response.statusCode, headers: response, body: data) {
            throw failure
        }
        return data
    }

    /// The one place status codes become meanings. `410` in particular is not
    /// `404`: it is what tells the owner their own link was withdrawn rather
    /// than mistyped, and the share sheet says different things about the two.
    static func failure(
        status: Int,
        headers: HTTPURLResponse?,
        body: Data
    ) -> ShareError? {
        switch status {
        case 200..<300:
            return nil
        case 401, 403:
            return .unauthorized
        case 404:
            return .notFound
        case 410:
            return .revoked
        case 429:
            return .rateLimited(retryAfter: retryAfter(headers))
        default:
            return .server(status: status, message: message(from: body))
        }
    }

    /// `Retry-After` is advisory and may be absent or an HTTP date; only a
    /// plain seconds count is used, and anything else degrades to "try again
    /// shortly" rather than to a number invented here.
    private static func retryAfter(_ response: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds >= 0
        else { return nil }
        return seconds
    }

    private static func message(from body: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body),
           let message = decoded.message {
            return message
        }
        let text = String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(200))
    }

    private func decodedShareID(_ data: Data) -> String? {
        try? JSONDecoder().decode(CreateResponse.self, from: data).id
    }

    private func encode(_ value: some Encodable) throws -> Data {
        do {
            return try SharePayloadBuilder.encoder.encode(value)
        } catch {
            throw ShareError.transport("The share could not be prepared for upload.")
        }
    }
}

private struct CreateBody: Encodable {
    let includes: ShareIncludes
    let payload: SharePayload
    let password: String?
}

private struct UpdateBody: Encodable {
    let includes: ShareIncludes
    let payload: SharePayload
}

/// `password` is written even when nil: `null` is what clears a password, and
/// an omitted key would read as "leave it alone".
private struct PasswordBody: Encodable {
    let password: String?

    private enum CodingKeys: String, CodingKey { case password }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let password {
            try container.encode(password, forKey: .password)
        } else {
            try container.encodeNil(forKey: .password)
        }
    }
}

/// The server names the field `id`; `shareID` is accepted too so a rename on
/// one side of the repository does not silently orphan a freshly created share
/// whose id this app then never learned.
private struct CreateResponse: Decodable {
    let id: String

    private enum CodingKeys: String, CodingKey {
        case id
        case shareID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(String.self, forKey: .id) {
            self.id = id
        } else {
            id = try container.decode(String.self, forKey: .shareID)
        }
    }
}

private struct ErrorBody: Decodable {
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case error
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? container.decodeIfPresent(String.self, forKey: .error)
    }
}
