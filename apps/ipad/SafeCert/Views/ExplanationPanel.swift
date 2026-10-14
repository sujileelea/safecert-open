import SafeCertKit
import SwiftUI

/// 오른쪽 텍스트 설명: 전체 요약 → 판정 카드(선택 시 7단 상세·조문 원문).
struct ExplanationPanel: View {
    let result: AnalysisResult
    let plan: PlanModel
    let snapshot: LawSnapshot?
    @Binding var selectedID: String?

    @State private var plainDraft: String?
    @State private var drafting = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summary
                    ForEach(Array(result.verdicts.enumerated()), id: \.element.id) { i, v in
                        VerdictCard(
                            verdict: v,
                            number: i + 1,
                            isSelected: selectedID == v.id,
                            explanation: snapshot.map { ExplanationComposer.explain(v, result: result, plan: plan, snapshot: $0) }
                        )
                        .id(v.id)
                        .onTapGesture {
                            withAnimation(.snappy) { selectedID = selectedID == v.id ? nil : v.id }
                        }
                    }
                    plainLanguage
                    footer
                }
                .padding(16)
            }
            .onChange(of: selectedID) { _, id in
                if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) } }
            }
        }
        .background(Theme.background)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if result.summary.isReserved {
                    Chip(text: "유보", tint: Theme.reserved)
                }
                Text(result.summary.subline).font(Theme.captionFont).foregroundStyle(Theme.secondary)
            }
            Text(result.summary.headline).font(Theme.titleFont).foregroundStyle(Theme.ink)
            HStack(spacing: 14) {
                ForEach(VerdictColor.allCases, id: \.self) { c in
                    if let n = result.summary.counts[c], n > 0 {
                        HStack(spacing: 5) {
                            ColorDot(color: c)
                            Text("\(c.meaning) \(n)").font(Theme.captionFont).foregroundStyle(Theme.ink)
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ExplanationComposer.narrative(result).dropFirst(), id: \.self) { line in
                    Text(line).font(Theme.captionFont).foregroundStyle(Theme.secondary)
                }
            }
        }
        .card()
    }

    @ViewBuilder
    private var plainLanguage: some View {
        if let client = KeychainStore.gemini {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("쉬운 말 요약").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Chip(text: "외부 AI(Gemini) 초안 · 판정에 쓰지 않음")
                }
                if let plainDraft {
                    Text(plainDraft).font(Theme.bodyFont).foregroundStyle(Theme.ink)
                } else {
                    Button(drafting ? "작성 중…" : "초안 만들기") {
                        drafting = true
                        Task {
                            plainDraft = await PlainLanguageDrafter.draft(for: result, client: client) ?? "초안을 받지 못했거나 사실 대조를 통과하지 못해 표시하지 않는다."
                            drafting = false
                        }
                    }
                    .disabled(drafting)
                    Text("누르면 판정 결과 글이 Google Gemini 로 전송된다(도면은 보내지 않음).")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .card()
        }
    }

    private var footer: some View {
        Text("색은 현행 법령상 지위, 배지는 판정 확실성이다. 판정은 규칙 엔진이 법령 스냅샷 \(result.snapshotID) 기준으로 결정적으로 내렸고, 유자격 전문가 감수 전 결과다.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 4)
    }
}

struct VerdictCard: View {
    let verdict: Verdict
    let number: Int
    let isSelected: Bool
    let explanation: VerdictExplanation?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Theme.color(verdict.color), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(verdict.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(verdict.target).font(Theme.captionFont).foregroundStyle(Theme.secondary)
                    Text(verdict.summary).font(Theme.bodyFont).foregroundStyle(Theme.ink)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { chips }
                        VStack(alignment: .leading, spacing: 4) { chips }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "chevron.up" : "chevron.down").foregroundStyle(Theme.secondary)
            }
            if isSelected, let explanation {
                Divider()
                detail(explanation)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Theme.color(verdict.color) : Theme.hairline, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var chips: some View {
        Chip(text: verdict.color.meaning, tint: Theme.color(verdict.color))
        Chip(text: verdict.badge.displayName)
        ForEach(verdict.lawFlags, id: \.self) { f in
            if case .recentlyRevised = f { Chip(text: "최근 개정", tint: Theme.color(.yellow)) }
            if case .pendingAmendment = f { Chip(text: "개정 예정", tint: Theme.color(.yellow)) }
            if case .staleSnapshot = f { Chip(text: "법령 수집 실패", tint: Theme.color(.orange)) }
            if case .clauseCarried = f { Chip(text: "일부 수집 실패", tint: Theme.color(.orange)) }
        }
    }

    @ViewBuilder
    private func detail(_ e: VerdictExplanation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(e.sections) { s in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(s.number). \(s.title)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                    ForEach(s.lines, id: \.self) { line in
                        Text(line).font(Theme.bodyFont).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    if s.number == 4 {
                        ForEach(e.citations) { c in
                            DisclosureGroup {
                                Text(c.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.ink)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                            } label: {
                                Text("원문 · \(c.citation)").font(Theme.captionFont).foregroundStyle(Theme.ink)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("법령 상태").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                ForEach(e.lawStatus, id: \.self) { line in
                    Text(line).font(Theme.captionFont).foregroundStyle(Theme.ink)
                }
            }
        }
    }
}
