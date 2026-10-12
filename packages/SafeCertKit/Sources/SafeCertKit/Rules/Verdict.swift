import Foundation

/// 색 = 현행 법령상 지위(기능명세서 §6). 파일럿은 파랑(권고)을 쓰지 않는다.
public enum VerdictColor: String, Codable, Sendable, CaseIterable, Comparable {
    case red, orange, yellow, green, gray

    public var displayName: String {
        switch self {
        case .red: "빨강"
        case .orange: "주황"
        case .yellow: "노랑"
        case .green: "초록"
        case .gray: "회색"
        }
    }

    public var meaning: String {
        switch self {
        case .red: "의무 미충족"
        case .orange: "위반 가능성 · 확인 필요"
        case .yellow: "기준 변경·개정 영향"
        case .green: "확인 범위 내 적합"
        case .gray: "자료 부족 · 대상 외"
        }
    }

    var order: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.order < b.order }

    /// 위험 후보 = 빨강·주황·노랑.
    public var isRiskCandidate: Bool { self == .red || self == .orange || self == .yellow }
}

/// 배지 = 판정 확실성.
public enum Badge: String, Codable, Sendable {
    case autoConfirmed
    case expertCheck
    case fieldCheck
    case insufficient

    public var displayName: String {
        switch self {
        case .autoConfirmed: "자동확인"
        case .expertCheck: "전문가확인 필요"
        case .fieldCheck: "현장확인 필요"
        case .insufficient: "자료불충분"
        }
    }
}

/// 값 출처(기능명세서 §2 값 4종 + 법령 기준값).
public enum ValueSource: String, Codable, Sendable {
    case drawingExtracted
    case drawingComputed
    case userInput
    case lawCriterion

    public var displayName: String {
        switch self {
        case .drawingExtracted: "도면 추출값"
        case .drawingComputed: "도면 계산값"
        case .userInput: "사용자 입력값"
        case .lawCriterion: "법령 기준값"
        }
    }
}

public struct ReadValue: Hashable, Codable, Sendable {
    public var label: String
    public var value: String
    public var source: ValueSource

    public init(_ label: String, _ value: String, _ source: ValueSource) {
        self.label = label
        self.value = value
        self.source = source
    }
}

/// 법령 상태 표식.
public enum LawFlag: Hashable, Codable, Sendable {
    case criterionUnverified(String)
    case interpretationChanged(String)
    case criterionUnavailable
    case recentlyRevised(String)
    case pendingAmendment(lawName: String, effectiveDate: String)
    case staleSnapshot(baseDate: String)
    case relatedNoticeChanged(String)

    public var text: String {
        switch self {
        case .criterionUnverified(let n): "기준 변경 감지 · 자동 검증 실패 — \(n)"
        case .interpretationChanged(let n): "해석 변경 가능 · 미반영 — \(n)"
        case .criterionUnavailable: "법령 기준 미확정"
        case .recentlyRevised(let d): "최근 개정 · 자동 검증(\(d) 반영)"
        case .pendingAmendment(let name, let date): "개정 예정 — \(name) \(LawDate.pretty(date)) 시행"
        case .staleSnapshot(let d): "법령 수집 실패 — 기준일 \(d) 의 법령으로 판정"
        case .relatedNoticeChanged(let n): "관련 고시 변동 — \(n)"
        }
    }

    /// 색을 노랑으로 바꾸는 표식인가(그 외는 보조 표식).
    public var overridesColor: Bool {
        switch self {
        case .criterionUnverified, .interpretationChanged: true
        default: false
        }
    }
}

public enum RuleKey: String, Codable, Sendable, CaseIterable {
    case exitRequired
    case exitLocation
    case exitSize

    public var title: String {
        switch self {
        case .exitRequired: "비상구 설치"
        case .exitLocation: "비상구 위치(이격거리)"
        case .exitSize: "비상구등 규격"
        }
    }

    public var criteria: [CriterionKey] {
        switch self {
        case .exitRequired: [.exitRequired, .existingExemption]
        case .exitLocation: [.exitLocation]
        case .exitSize: [.exitSize]
        }
    }

    public var clauses: [ClauseKey] {
        switch self {
        case .exitRequired: [.decreeExitRequired, .decreeDefinitions, .actDuty, .noticeExistingGeneral]
        case .exitLocation: [.ruleExitLocation, .actDuty]
        case .exitSize: [.ruleExitSize, .actDuty]
        }
    }
}

/// 도면 위 표시 위치.
public struct VerdictLocation: Hashable, Codable, Sendable {
    public var markers: [Point]
    public var line: Segment?
    public var area: Polygon?

    public init(markers: [Point] = [], line: Segment? = nil, area: Polygon? = nil) {
        self.markers = markers
        self.line = line
        self.area = area
    }
}

public struct Verdict: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var rule: RuleKey
    public var target: String
    public var color: VerdictColor
    public var badge: Badge
    /// 결과 한 줄(「읽은 값 vs 기준」).
    public var summary: String
    public var readValues: [ReadValue]
    public var criteria: [ReadValue]
    /// 왜 이 규칙이 적용되는가.
    public var applicability: String
    public var checkItems: [String]
    public var lawFlags: [LawFlag]
    /// 객체 인식 신뢰도(0~1).
    public var confidence: Double
    public var location: VerdictLocation

    public var title: String { rule.title }
}

public struct AnalysisSummary: Hashable, Codable, Sendable {
    public var counts: [VerdictColor: Int]
    public var riskCandidates: Int
    /// 치명 규칙(피난·출구)에 회색·주황·노랑이 있으면 유보(V-07 ①).
    public var isReserved: Bool
    public var needsCheck: Int

    /// 감수 전 표현만 쓴다(V-07 ③): 「적합·부적합」 단어를 쓰지 않는다.
    public var headline: String {
        isReserved ? "판정 유보 — 확인 필요 \(needsCheck)건" : "자동검토상 위험 후보 \(riskCandidates)건"
    }

    public var subline: String { "감수 전 · 참고용" }
}

/// 판정 1회 결과.
public struct AnalysisResult: Hashable, Codable, Sendable {
    public var verdicts: [Verdict]
    public var summary: AnalysisSummary
    public var snapshotID: String
    public var lawBaseDate: String
    public var scale: ScaleEstimate?
    public var conditions: Conditions
    public var areaSquareMeters: Double?
    public var roomCount: Int
    public var notes: [String]
}
