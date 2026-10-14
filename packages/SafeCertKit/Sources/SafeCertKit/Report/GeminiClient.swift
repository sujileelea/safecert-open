import Foundation
import os

/// 외부 생성형 LLM — Google Gemini API(무료 티어) 구조화 생성. 외부 라이브러리 없이 URLSession 으로 호출한다.
/// 보내는 것은 판정 결과 글과 법령 조문뿐이다(도면 파일·이미지·검토 이름은 보내지 않는다). 키는 로그에 남기지 않는다.
public struct GeminiClient: Sendable {
    public static let defaultModel = "gemini-3.5-flash-lite"
    static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/"
    static let log = Logger(subsystem: "com.alnair.safecert", category: "gemini")

    public enum Failure: Error, Equatable {
        case http(status: Int, message: String)
        case emptyResponse
        case invalidJSON(String)
    }

    let apiKey: String
    public let model: String
    let session: URLSession

    public init(apiKey: String, model: String = defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// 시스템 지시 + 사용자 글 → 응답 스키마에 맞는 JSON 을 T 로. 일시 오류(429·5xx)는 한 번 다시 시도한다.
    public func generate<T: Decodable>(_ type: T.Type, system: String, prompt: String, schema: String, maxOutputTokens: Int = 800) async throws -> T {
        let request = try makeRequest(system: system, prompt: prompt, schema: schema, maxOutputTokens: maxOutputTokens)
        do {
            return try await send(request, as: type)
        } catch Failure.http(let status, _) where status == 429 || status >= 500 {
            try await Task.sleep(for: .seconds(2))
            return try await send(request, as: type)
        }
    }

    func makeRequest(system: String, prompt: String, schema: String, maxOutputTokens: Int) throws -> URLRequest {
        guard let url = URL(string: "\(Self.endpoint)\(model):generateContent"),
              let schemaObject = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any] else {
            throw Failure.invalidJSON("요청 스키마")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0,
                "maxOutputTokens": maxOutputTokens,
                "responseMimeType": "application/json",
                "responseSchema": schemaObject,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message ?? "응답 \(status)"
            Self.log.error("Gemini 호출 실패 \(status, privacy: .public): \(message, privacy: .public)")
            throw Failure.http(status: status, message: message)
        }
        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        guard let text = envelope.candidates?.first?.content?.parts?.compactMap(\.text).joined(), !text.isEmpty else {
            throw Failure.emptyResponse
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw Failure.invalidJSON(String(text.prefix(200)))
        }
    }

    struct ResponseEnvelope: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { var text: String? }
                var parts: [Part]?
            }
            var content: Content?
        }
        var candidates: [Candidate]?
        var modelVersion: String?
    }

    struct ErrorEnvelope: Decodable {
        struct Body: Decodable { var message: String }
        var error: Body
    }
}

/// 보고서·쉬운 말 요약에 공통으로 주는 지시.
enum WritingRules {
    static let report = """
    너는 소방 도면 사전검토 보고서를 쓰는 작성자다. 독자는 다중이용업소 영업장을 설계·시공하는 실무자다.
    규칙:
    1. 주어진 「사실」과 「조문」에 있는 내용만 쓴다. 사실에 없는 숫자·면적·거리·날짜·조항 번호를 만들지 않는다.
    2. 판정 색과 결과는 사실에 적힌 그대로 전한다. 더 좋게도 더 나쁘게도 바꾸지 않는다. 색과 항목의 짝을 바꾸지 않는다.
    3. 「적합」「부적합」「안전하다」「위반이다」처럼 단정하는 말을 쓰지 않는다. 전문가 감수 전 결과다.
    4. 벌금·과태료 금액·공사비·손해액을 쓰지 않는다.
    5. 보고서 문체(~다)로 간결하게 쓴다.
    """
}

/// 보고서 서술 — 외부 생성형 LLM(Gemini). 판정마다 따로 호출하고(앞 판정 내용이 섞이지 않게) 온도 0 으로 쓴다.
public struct GeminiReportNarrator: ReportNarrating {
    let client: GeminiClient

    public init(client: GeminiClient) {
        self.client = client
    }

    public var modelName: String { "Google Gemini(\(client.model) · 외부 LLM)" }

    struct SummaryOut: Decodable { var summary: String }
    struct VerdictOut: Decodable {
        var explanation: String
        var nextSteps: [String]
    }

    static let summarySchema = """
    {"type":"OBJECT","properties":{"summary":{"type":"STRING","description":"검토 결과 전체를 실무자에게 알리는 보고서 문체(~다) 한국어 3~4문장"}},"required":["summary"]}
    """
    static let verdictSchema = """
    {"type":"OBJECT","properties":{"explanation":{"type":"STRING","description":"이 판정이 무엇을 확인했고 왜 이런 결과가 나왔는지 보고서 문체(~다) 한국어 2~3문장"},"nextSteps":{"type":"ARRAY","items":{"type":"STRING"},"description":"도면 작성자가 다음에 확인하거나 보완할 일 1~3개. 항목마다 보고서 문체 한 문장"}},"required":["explanation","nextSteps"]}
    """

    public func summary(facts: String) async -> String? {
        do {
            return try await client.generate(SummaryOut.self, system: WritingRules.report,
                                             prompt: "사실:\n\(facts)\n\n검토 결과 전체 요약을 써라.", schema: Self.summarySchema).summary
        } catch {
            GeminiClient.log.error("요약 생성 실패: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func verdict(facts: String, passages: String) async -> (explanation: String, nextSteps: [String])? {
        do {
            let out = try await client.generate(VerdictOut.self, system: WritingRules.report,
                                                prompt: "사실:\n\(facts)\n\n조문:\n\(passages)\n\n이 판정의 설명과 확인·보완할 일을 써라.",
                                                schema: Self.verdictSchema)
            return (out.explanation, Array(out.nextSteps.prefix(3)))
        } catch {
            GeminiClient.log.error("판정 설명 생성 실패: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
