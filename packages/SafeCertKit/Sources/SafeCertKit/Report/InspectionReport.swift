import Foundation

/// 보고서의 서술 한 덩어리. AI 가 쓴 문장은 사실·조문 대조를 통과한 것만 남고, 못 쓰면 규칙 엔진 문장으로 채운다.
public struct ReportNarrative: Hashable, Codable, Sendable {
    public var sentences: [String]
    /// true = 생성형 AI 가 쓴 문장(대조 통과분), false = 규칙 엔진이 만든 정해진 문장.
    public var isAI: Bool
    /// AI 가 썼지만 대조에 걸려 뺀 문장 수.
    public var dropped: Int

    public init(sentences: [String], isAI: Bool, dropped: Int = 0) {
        self.sentences = sentences
        self.isAI = isAI
        self.dropped = dropped
    }

    public var text: String { sentences.joined(separator: " ") }
}

/// 판정 하나의 보고서 절.
public struct ReportVerdictSection: Hashable, Codable, Sendable, Identifiable {
    public var number: Int
    public var verdict: Verdict
    /// 7단 상세(규칙 엔진 · 결정적).
    public var explanation: VerdictExplanation
    /// 판정 설명(AI).
    public var narrative: ReportNarrative
    /// 확인·보완 방향(AI) — 문장마다 한 항목.
    public var nextSteps: ReportNarrative
    /// 조문 검색으로 찾은 관련 구절(원문).
    public var related: [RetrievedPassage]
    /// 검토자가 이 판정을 확인한 시각(체크). nil = 미확인.
    public var confirmedAt: Date?

    public var id: String { verdict.id }
}

/// 도면 사전검토 보고서(기능명세서 X-01). 판정·색·값·조문 원문은 판정 결과 그대로이고, AI 는 서술만 쓴다.
public struct InspectionReport: Hashable, Codable, Sendable {
    public var title: String
    public var projectName: String
    public var fileName: String
    public var createdAt: Date
    public var judgedAt: Date
    public var result: AnalysisResult
    public var lawSource: String
    public var scope: [String]
    public var summary: ReportNarrative
    public var sections: [ReportVerdictSection]
    public var lawStatus: [String]
    public var notes: [String]
    /// 서술에 쓴 모델(못 쓰면 nil).
    public var model: String?

    /// 검토자가 확인(체크)한 판정 수.
    public var confirmedCount: Int { sections.filter { $0.confirmedAt != nil }.count }

    public static let disclaimer = "소프트웨어 사전검토 결과다. 최종 확인은 유자격 전문가가 한다."
    public static let aiNotice = "AI 작성 표시가 붙은 문장은 생성형 AI 가 판정 결과와 법령 원문만 보고 쓴 설명이다. 판정·색·수치는 AI 가 아니라 규칙 엔진이 정했다."

    /// AI 가 쓴 문장 수 / 대조로 뺀 문장 수.
    public var aiSentenceCount: Int {
        ([summary] + sections.flatMap { [$0.narrative, $0.nextSteps] }).filter(\.isAI).map(\.sentences.count).reduce(0, +)
    }

    public var droppedSentenceCount: Int {
        ([summary] + sections.flatMap { [$0.narrative, $0.nextSteps] }).map(\.dropped).reduce(0, +)
    }
}

/// 보고서 서술을 맡는 생성형 모델. 사실(facts)과 조문 원문만 받는다.
public protocol ReportNarrating: Sendable {
    var modelName: String { get }
    /// 전체 요약 3~4문장.
    func summary(facts: String) async -> String?
    /// 판정 설명 2~3문장 + 확인·보완 방향 1~3항목.
    func verdict(facts: String, passages: String) async -> (explanation: String, nextSteps: [String])?
}
