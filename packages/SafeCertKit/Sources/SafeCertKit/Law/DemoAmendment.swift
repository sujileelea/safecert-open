import Foundation

/// 시연용 가상 법령 변경 — 「조문 문구가 바뀌어 자동 반영하지 않은」 상황을 실제 수집 없이 만든다.
/// 실제 스냅샷은 건드리지 않고 사본을 돌려준다. 사본의 ID 끝은 「-demo」, 출처에 시연용임을 적는다.
public extension LawSnapshot {
    static let demoSuffix = "-demo"

    /// 시연용 가상 변경 스냅샷인가.
    var isDemo: Bool { id.hasSuffix(Self.demoSuffix) }

    func simulatingAmendment(of key: CriterionKey) -> LawSnapshot {
        var s = self
        s.id = id + Self.demoSuffix
        s.source = "시연용 가상 법령 변경 — 실제 법령과 무관 (원래 출처: \(source))"
        if let i = s.criteria.firstIndex(where: { $0.key == key }) {
            s.criteria[i].status = .interpretationChanged
            s.criteria[i].note = "시연: 조문 문구가 바뀐 상황(가상) — 자동 반영하지 않고 이전 기준 유지"
        }
        s.events.append(LawChangeEvent(kind: .wordingChanged, subject: key.clauseKey.citation, detail: "시연: 문구 변경 감지(가상)"))
        s.events.append(LawChangeEvent(kind: .criterionRejected, subject: key.displayName, detail: "시연: 자동 반영하지 않음 — 이전 값 유지, 해당 판정 노랑"))
        return s
    }
}
