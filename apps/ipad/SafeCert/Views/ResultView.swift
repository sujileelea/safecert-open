import SafeCertKit
import SwiftUI

/// 결과: 도면 위 색 표시(약 2/3) + 별도 텍스트 설명(오른쪽).
struct ResultView: View {
    let project: ReviewProject
    let prepared: PreparedDrawing
    let record: AnalysisRecord
    let result: AnalysisResult
    let onEdit: () -> Void
    let onRejudge: () -> Void

    @Environment(LawStore.self) private var law
    @State private var selectedID: String?

    private var snapshot: LawSnapshot? { law.snapshot(id: record.snapshotID) }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            GeometryReader { geo in
                let canvas = DrawingCanvas(pdf: project.pdfData, pageIndex: project.pageIndex, plan: prepared.plan,
                                           mode: .verdicts(result.verdicts), selectedID: $selectedID)
                let panel = ExplanationPanel(result: result, plan: prepared.plan, snapshot: snapshot, selectedID: $selectedID)
                if geo.size.width > geo.size.height {
                    // 가로: 도면 왼쪽 · 설명 오른쪽
                    HStack(spacing: 0) {
                        canvas.frame(width: geo.size.width * 0.62)
                        Divider()
                        panel
                    }
                } else {
                    // 세로: 도면 위 · 설명 아래
                    VStack(spacing: 0) {
                        canvas.frame(height: geo.size.height * 0.5)
                        Divider()
                        panel
                    }
                }
            }
        }
        #if DEBUG
        .onAppear {
            if let n = DemoLaunch.arguments["-SafeCertDemoSelect"].flatMap(Int.init), n >= 1, n <= result.verdicts.count {
                selectedID = result.verdicts[n - 1].id
            }
        }
        #endif
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text("판정 \(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · 법령 기준일 \(result.lawBaseDate)")
                .font(Theme.captionFont).foregroundStyle(Theme.secondary)
            if let current = law.current, current.id != result.snapshotID {
                Chip(text: "새 법령 스냅샷 \(current.baseDate) 있음", tint: Theme.color(.yellow))
            }
            Spacer()
            Button("축척·조건 수정", action: onEdit)
            Button("최신 법령으로 다시 판정", action: onRejudge)
                .fontWeight(.semibold)
        }
        .font(Theme.bodyFont)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Divider() }
    }
}
