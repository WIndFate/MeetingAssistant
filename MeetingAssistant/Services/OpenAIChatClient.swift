import CryptoKit
import Foundation

/// Minimal streaming client for OpenAI Chat Completions. Plain HTTPS + SSE,
/// no SDK: one system message (cacheable prefix) and one user message.
struct OpenAIChatClient {
    let apiKey: String
    var session: URLSession = .shared

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func stream(
        model: String,
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        model: model,
                        system: system,
                        user: user,
                        maxTokens: maxTokens,
                        temperature: temperature
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                        }
                        throw OpenAIChatError.http(status: status, body: body)
                    }
                    for try await line in bytes.lines {
                        switch OpenAIStreamParser.parse(line: line) {
                        case .content(let text):
                            continuation.yield(text)
                        case .done:
                            continuation.finish()
                            return
                        case .ignore:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(
        model: String,
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double
    ) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "max_completion_tokens": maxTokens,
            "temperature": temperature,
            "stream": true,
            // Route identical system prompts to the same cache shard.
            "prompt_cache_key": "meeting-assistant:\(model):\(Self.fingerprint(system))",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

enum OpenAIChatError: LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is not set. Open Settings to add it."
        case .http(let status, let body):
            switch status {
            case 401, 403:
                return "OpenAI rejected the API key or model access (HTTP \(status))."
            case 429:
                return body.contains("insufficient_quota")
                    ? "OpenAI quota is used up. Check billing."
                    : "OpenAI rate limit hit. Retry shortly."
            case 500...599:
                return "OpenAI is temporarily unavailable (HTTP \(status))."
            default:
                return "OpenAI request failed (HTTP \(status)): \(body.prefix(200))"
            }
        }
    }
}

/// Parses one line of the Chat Completions server-sent event stream.
enum OpenAIStreamParser {
    enum Event: Equatable {
        case content(String)
        case done
        case ignore
    }

    static func parse(line: String) -> Event {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty
        else { return .ignore }
        return .content(content)
    }
}
