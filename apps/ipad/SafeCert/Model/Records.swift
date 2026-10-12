import Foundation
import SafeCertKit
import SwiftData

/// 검토 1건 = 도면 하나 + 조건 + 판정 이력.
@Model
final class ReviewProject {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var fileName: String
    @Attribute(.externalStorage) var pdfData: Data
    var pageIndex: Int
    var conditionsData: Data
    /// 자동 추정 축척 확인 토글(U-04·U-07).
    var scaleConfirmed: Bool
    /// 사용자가 직접 입력한 축척 1:N.
    var scaleRatioOverride: Int?
    var sampleID: String?
    @Relationship(deleteRule: .cascade, inverse: \AnalysisRecord.project)
    var analyses: [AnalysisRecord] = []

    init(name: String, fileName: String, pdfData: Data, sampleID: String? = nil) {
        id = UUID()
        self.name = name
        createdAt = Date()
        updatedAt = Date()
        self.fileName = fileName
        self.pdfData = pdfData
        pageIndex = 0
        conditionsData = (try? JSONEncoder().encode(Conditions())) ?? Data()
        scaleConfirmed = false
        scaleRatioOverride = nil
        self.sampleID = sampleID
    }

    var conditions: Conditions {
        get { (try? JSONDecoder().decode(Conditions.self, from: conditionsData)) ?? Conditions() }
        set {
            conditionsData = (try? JSONEncoder().encode(newValue)) ?? conditionsData
            updatedAt = Date()
        }
    }

    var latestAnalysis: AnalysisRecord? { analyses.max { $0.createdAt < $1.createdAt } }

    /// 판정에 쓸 축척: 직접 입력 > 자동 추정(확인 토글 반영).
    func effectiveScale(_ estimate: ScaleEstimate?) -> ScaleEstimate? {
        if let n = scaleRatioOverride {
            return ScaleEstimate(ratio: n, source: .user, crossChecks: estimate?.ratio == n ? estimate?.crossChecks ?? 0 : 0,
                                 evidence: ["사용자 입력 1:\(n)"], confirmed: true)
        }
        guard var s = estimate else { return nil }
        s.confirmed = scaleConfirmed
        return s
    }
}

@Model
final class AnalysisRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var snapshotID: String
    var lawBaseDate: String
    var resultData: Data
    var project: ReviewProject?

    init(result: AnalysisResult) {
        id = UUID()
        createdAt = Date()
        snapshotID = result.snapshotID
        lawBaseDate = result.lawBaseDate
        resultData = (try? JSONEncoder().encode(result)) ?? Data()
    }

    var result: AnalysisResult? { try? JSONDecoder().decode(AnalysisResult.self, from: resultData) }
}

/// 법령 스냅샷 이력. 판정은 스냅샷 번호로 법령 기준을 고정한다.
@Model
final class LawSnapshotRecord {
    @Attribute(.unique) var snapshotID: String
    var checkedAt: Date
    var baseDate: String
    var isSeed: Bool
    var isStale: Bool
    var payload: Data

    init(_ s: LawSnapshot) {
        snapshotID = s.id
        checkedAt = s.checkedAt
        baseDate = s.baseDate
        isSeed = s.isSeed
        isStale = s.isStale
        payload = (try? JSONEncoder().encode(s)) ?? Data()
    }

    var snapshot: LawSnapshot? { try? JSONDecoder().decode(LawSnapshot.self, from: payload) }
}
