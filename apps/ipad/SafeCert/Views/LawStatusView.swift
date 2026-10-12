import SafeCertKit
import SwiftUI

/// 법령 현황: 오늘 스냅샷 · 기준별 코드 검증 5종 · 조문 원문 · 개정 예정 · 변경 기록.
struct LawStatusView: View {
    @Environment(LawStore.self) private var law
    @State private var openClause: LawClause?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let s = law.current {
                    header(s)
                    criteria(s)
                    clauses(s)
                    if !s.pendingAmendments.isEmpty { pending(s) }
                    events(s)
                } else {
                    ProgressView("법령 스냅샷 준비 중").frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationTitle("법령 현황")
        .sheet(item: $openClause) { c in
            NavigationStack {
                ScrollView {
                    Text(c.text).font(Theme.bodyFont).textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(c.citation)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { openClause = nil } } }
            }
        }
    }

    private func header(_ s: LawSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("법령 기준일 \(s.baseDate)").font(Theme.titleFont)
                Spacer()
                Button(law.isSyncing ? "실측 중…" : "지금 실측") { Task { await law.sync() } }
                    .disabled(law.isSyncing)
                    .fontWeight(.semibold)
            }
            HStack(spacing: 8) {
                Chip(text: s.isStale ? "수집 실패 · 이전 기준 사용" : s.isSeed ? "번들 초기값" : "실측 정상",
                     tint: s.isStale ? Theme.color(.orange) : s.isSeed ? Theme.secondary : Theme.color(.green))
                Chip(text: "스냅샷 \(s.id)")
                Chip(text: s.source)
            }
            Text("마지막 확인 \(s.checkedAt.formatted(date: .abbreviated, time: .shortened))" +
                 (law.nextScheduled.map { " · 다음 정시 실측 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                .font(Theme.captionFont).foregroundStyle(Theme.secondary)
            Text("매일 05:00(KST) 국가법령정보 공동활용 API 에서 현행 법령·소방청 고시를 실측하고, 조문을 정규화해 코드 검증 5종을 통과한 값만 판정에 쓴다. iPadOS 가 정시 실행을 보장하지 않으므로 앱을 열 때·판정 전에 당일 실측이 없으면 즉시 실측한다.")
                .font(Theme.captionFont).foregroundStyle(Theme.secondary)
            if law.usesSampleKey {
                Label("공개 샘플 인증값으로 호출 중 — 운영 전 발급받은 인증값을 설정에 넣는다.", systemImage: "key")
                    .font(Theme.captionFont).foregroundStyle(Theme.color(.orange))
            }
            if !s.collectionErrors.isEmpty {
                ForEach(s.collectionErrors, id: \.self) { Text($0).font(Theme.captionFont).foregroundStyle(Theme.color(.red)) }
            }
        }
        .card()
    }

    private func criteria(_ s: LawSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("판정 기준 · 코드 검증").font(.system(size: 15, weight: .semibold))
            ForEach(s.criteria, id: \.key) { st in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(st.key.displayName).font(Theme.bodyFont)
                        Spacer()
                        statusChip(st.status)
                    }
                    if let c = st.criterion {
                        Text(c.values.sorted { $0.key < $1.key }.map { "\(label($0.key)) \($0.value.display)" }.joined(separator: " · "))
                            .font(Theme.captionFont).foregroundStyle(Theme.ink)
                    }
                    HStack(spacing: 10) {
                        ForEach(st.checks, id: \.kind) { check in
                            HStack(spacing: 3) {
                                Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(check.passed ? Theme.color(.green) : Theme.color(.red))
                                Text(check.kind.displayName).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            }
                            .help(check.detail)
                        }
                    }
                    if let note = st.note { Text(note).font(Theme.captionFont).foregroundStyle(Theme.color(.orange)) }
                    if let r = st.revisedOn { Text("개정 반영일 \(r)").font(Theme.captionFont).foregroundStyle(Theme.secondary) }
                }
                if st.key != s.criteria.last?.key { Divider() }
            }
        }
        .card()
    }

    private func clauses(_ s: LawSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("인용 조문(그날 원문)").font(.system(size: 15, weight: .semibold))
            ForEach(s.clauses) { c in
                Button { openClause = c } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.citation).font(Theme.bodyFont).foregroundStyle(Theme.ink)
                            Text("\(c.layer.rawValue) · 시행 \(LawDate.pretty(c.effectiveDate)) · 지문 \(c.fingerprint.prefix(10))")
                                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    private func pending(_ s: LawSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("개정 예정(공포 후 미시행)").font(.system(size: 15, weight: .semibold))
            ForEach(s.pendingAmendments, id: \.self) { p in
                Text("\(p.lawName) · \(LawDate.pretty(p.effectiveDate)) 시행").font(Theme.bodyFont)
            }
        }
        .card()
    }

    private func events(_ s: LawSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("이번 실측 기록").font(.system(size: 15, weight: .semibold))
            if s.events.isEmpty {
                Text("전날과 같음 — 변경 없음").font(Theme.captionFont).foregroundStyle(Theme.secondary)
            }
            ForEach(s.events, id: \.self) { e in
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.subject).font(Theme.bodyFont)
                    Text(e.detail).font(Theme.captionFont).foregroundStyle(Theme.secondary)
                }
            }
            Divider()
            Text("최근 스냅샷").font(Theme.captionFont).foregroundStyle(Theme.secondary)
            ForEach(law.history(limit: 10), id: \.snapshotID) { r in
                Text("\(r.snapshotID) · 기준일 \(r.baseDate)\(r.isStale ? " · 수집 실패" : "")\(r.isSeed ? " · 초기값" : "")")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .card()
    }

    private func statusChip(_ s: CriterionState.Status) -> some View {
        switch s {
        case .verified: Chip(text: "검증 통과", tint: Theme.color(.green))
        case .rejected: Chip(text: "검증 실패 · 이전 값", tint: Theme.color(.yellow))
        case .interpretationChanged: Chip(text: "해석 변경 · 미반영", tint: Theme.color(.yellow))
        case .unavailable: Chip(text: "기준 없음", tint: Theme.color(.gray))
        }
    }

    private func label(_ name: String) -> String {
        switch name {
        case "ratio": "이격 비율"
        case "minWidth": "최소 가로"
        case "minHeight": "최소 세로"
        case "exemptionA.ratio": "예외 가목 비율"
        case "exemptionB.maxArea": "예외 나목 면적"
        case "exemptionB.maxDistance": "예외 나목 거리"
        case "cutoffDate": "기존 업소 기준일"
        case "maxArea": "면적 기준"
        default: name
        }
    }
}
