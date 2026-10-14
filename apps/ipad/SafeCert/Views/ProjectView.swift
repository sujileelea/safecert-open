import SafeCertKit
import SwiftData
import SwiftUI

/// 검토 1건: 확인 단계 ↔ 결과 단계.
struct ProjectView: View {
    @Bindable var project: ReviewProject

    @Environment(LawStore.self) private var law
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var prepared: PreparedDrawing?
    @State private var prepareError: String?
    @State private var showingResult = false
    @State private var judging = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let prepareError {
                    ContentUnavailableView("도면을 읽지 못했다", systemImage: "doc.questionmark", description: Text(prepareError))
                } else if let prepared {
                    if showingResult, let record = project.latestAnalysis, let result = record.result {
                        ResultView(project: project, prepared: prepared, record: record, result: result,
                                   onEdit: { showingResult = false }, onRejudge: { Task { await judge() } })
                    } else {
                        ConfirmView(project: project, prepared: prepared) { Task { await judge() } }
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView("도면 해석 중")
                        Text("글자가 외곽선으로 출력된 도면이면 기기 내 글자 인식에 수십 초 걸릴 수 있다(처음 한 번).")
                            .font(Theme.captionFont).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay {
                if judging {
                    ProgressView("판정 중").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: project.pageIndex) { await prepare() }
        .onAppear { showingResult = project.latestAnalysis != nil }
    }

    private var header: some View {
        HStack {
            StepperBar(current: showingResult ? 3 : 1)
            Spacer()
            if sizeClass != .compact {
                Text(project.fileName).font(Theme.captionFont).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.card)
    }

    private func prepare() async {
        prepared = nil
        prepareError = nil
        do {
            let page = project.pageIndex
            let result = try await AnalysisPipeline.prepare(pdf: project.pdfData, pageIndex: page, cachedTexts: project.recognizedTexts(page: page))
            if let texts = result.recognizedTexts, project.recognizedTexts(page: page) == nil {
                project.storeRecognizedTexts(texts, page: page)
                try? context.save()
            }
            prepared = result
        } catch {
            prepareError = "PDF 를 열 수 없다. CAD 에서 직접 출력한 벡터 PDF 를 올려 주세요."
        }
    }

    /// 판정 직전에 당일 법령 스냅샷을 보장하고, 결과를 이력으로 남긴다.
    private func judge() async {
        guard let prepared else { return }
        judging = true
        await law.ensureToday()
        guard let snapshot = law.current else {
            judging = false
            return
        }
        let result = await AnalysisPipeline.judge(prepared, scale: project.effectiveScale(prepared.scaleEstimate),
                                                  conditions: project.conditions, snapshot: snapshot)
        let record = AnalysisRecord(result: result)
        record.project = project
        context.insert(record)
        project.updatedAt = Date()
        try? context.save()
        judging = false
        withAnimation(.snappy) { showingResult = true }
    }
}
