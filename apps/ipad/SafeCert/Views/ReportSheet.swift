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
    /// 외부 LLM 전송 확인을 기다리는 중.
    @State private var askingConsent = false

    var body: some View {
        NavigationStack {
            Group {
                if askingConsent {
                    consent
                } else if let data = record.reportData {
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
                        Button("다시 작성") { start() }
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
            if record.reportData == nil { start() } else { writeFile() }
        }
    }

    /// AI 키가 있으면 외부 전송 확인부터, 없으면 바로 규칙 엔진 문장으로.
    private func start() {
        if KeychainStore.gemini != nil {
            askingConsent = true
        } else {
            Task { await make(useAI: false) }
        }
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI 문장 작성을 위해 외부로 보냅니다").font(.system(size: 19, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("보내는 것: 판정 결과 글(항목·색·읽은 값·기준)과 관련 법령 조문", systemImage: "arrow.up.doc")
                Label("보내지 않는 것: 도면 파일·도면 이미지·검토 이름", systemImage: "lock")
                Label("받는 곳: Google Gemini API(무료 티어) — 입력이 Google 제품 개선에 쓰일 수 있다", systemImage: "globe")
                Label("판정·색·수치는 바뀌지 않는다. AI 문장은 「AI 작성」 표시와 함께 실린다", systemImage: "checkmark.seal")
            }
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.ink)
            HStack(spacing: 12) {
                Button("AI 없이 작성") {
                    askingConsent = false
                    Task { await make(useAI: false) }
                }
                .buttonStyle(.bordered)
                Button("보내고 작성") {
                    askingConsent = false
                    Task { await make(useAI: true) }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(28)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progress: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("보고서 작성 중").font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("판정 결과·조문 원문 묶기(규칙 엔진)", systemImage: "checkmark.seal")
                Label("판정마다 관련 조문 검색", systemImage: "text.magnifyingglass")
                Label(usingAI ? "외부 AI(Gemini)로 설명 문장 작성 — 수십 초" : "AI 없이 규칙 엔진 문장으로 작성", systemImage: "sparkles")
                Label("AI 문장 근거 대조 → PDF 조판", systemImage: "doc.richtext")
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.secondary)
            Text(usingAI ? "도면 파일·이미지는 보내지 않는다." : "아무것도 기기 밖으로 나가지 않는다.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var usingAI = false

    private func make(useAI: Bool) async {
        guard let snapshot = law.snapshot(id: record.snapshotID) else {
            failure = "판정에 쓴 법령 스냅샷(\(record.snapshotID))을 찾지 못했다. 최신 법령으로 다시 판정한 뒤 만들어 주세요."
            return
        }
        working = true
        usingAI = useAI
        failure = nil
        record.reportData = nil
        let input = ReportInput(result: result, plan: prepared.plan, snapshot: snapshot, projectName: project.name,
                                fileName: project.fileName, judgedAt: record.createdAt)
        let narrator: (any ReportNarrating)? = useAI ? KeychainStore.gemini.map { GeminiReportNarrator(client: $0) } : nil
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
