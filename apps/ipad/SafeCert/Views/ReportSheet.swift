import PDFKit
import SafeCertKit
import SwiftUI

/// 도면 사전검토 보고서(X-01): 작성 → 미리보기 → 공유. 만든 PDF 는 판정 기록에 붙여 다시 열 때 재사용한다.
struct ReportSheet: View {
    let project: ReviewProject
    let prepared: PreparedDrawing
    let record: AnalysisRecord
    let result: AnalysisResult

    @Environment(LawStore.self) private var law
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var working = false
    @State private var failure: String?
    @State private var fileURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let data = record.reportData {
                    PDFPreview(data: data)
                } else if let failure {
                    ContentUnavailableView("보고서를 만들지 못했다", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else {
                    progress
                }
            }
            .background(Theme.background)
            .navigationTitle("사전검토 보고서")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
                if record.reportData != nil {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("다시 작성") { Task { await make() } }
                            .disabled(working)
                    }
                    if let fileURL {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: fileURL) { Label("공유", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
            }
        }
        .task {
            if record.reportData == nil { await make() } else { writeFile() }
        }
    }

    private var progress: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("보고서 작성 중").font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("판정 결과·조문 원문 묶기(규칙 엔진)", systemImage: "checkmark.seal")
                Label("판정마다 관련 조문 검색", systemImage: "text.magnifyingglass")
                Label(OnDeviceReportNarrator.isAvailable ? "기기 내 AI 로 설명 문장 작성 — 수십 초" : "이 기기에서 AI 를 쓸 수 없어 규칙 엔진 문장으로 작성",
                      systemImage: "sparkles")
                Label("AI 문장 근거 대조 → PDF 조판", systemImage: "doc.richtext")
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.secondary)
            Text("도면과 결과는 기기 밖으로 나가지 않는다.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func make() async {
        guard let snapshot = law.snapshot(id: record.snapshotID) else {
            failure = "판정에 쓴 법령 스냅샷(\(record.snapshotID))을 찾지 못했다. 최신 법령으로 다시 판정한 뒤 만들어 주세요."
            return
        }
        working = true
        failure = nil
        record.reportData = nil
        let input = ReportInput(result: result, plan: prepared.plan, snapshot: snapshot, projectName: project.name,
                                fileName: project.fileName, judgedAt: record.createdAt)
        let narrator: (any ReportNarrating)? = OnDeviceReportNarrator.isAvailable ? OnDeviceReportNarrator() : nil
        let report = await ReportBuilder.build(input, narrator: narrator)
        let pdf = project.pdfData, page = project.pageIndex, plan = prepared.plan
        let data = await Task.detached { ReportPDF.render(report, drawing: pdf, pageIndex: page, plan: plan) }.value
        record.reportData = data
        record.reportCreatedAt = report.createdAt
        try? context.save()
        writeFile()
        working = false
    }

    /// 공유용 임시 파일.
    private func writeFile() {
        guard let data = record.reportData else { return }
        let safe = project.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe)_사전검토보고서.pdf")
        do {
            try data.write(to: url, options: .atomic)
            fileURL = url
        } catch {
            fileURL = nil
        }
    }
}

/// PDFKit 미리보기.
struct PDFPreview: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = UIColor(Theme.background)
        view.document = PDFDocument(data: data)
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator(data: data) }

    func updateUIView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
    }

    final class Coordinator {
        var data: Data
        init(data: Data) { self.data = data }
    }
}
