import SafeCertKit
import SwiftUI
import UniformTypeIdentifiers

/// 새 검토: PDF 가져오기 또는 샘플 도면.
struct NewReviewSheet: View {
    let onCreate: (ReviewProject) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var pdf: Data?
    @State private var fileName = ""
    @State private var sampleID: String?
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("검토 이름").font(Theme.captionFont).foregroundStyle(Theme.secondary)
                        TextField("예: 강남점 1층 영업장", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    .card()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("도면").font(.system(size: 15, weight: .semibold))
                        Button {
                            importing = true
                        } label: {
                            HStack {
                                Image(systemName: pdf != nil && sampleID == nil ? "checkmark.circle.fill" : "doc.badge.plus")
                                Text(pdf != nil && sampleID == nil ? "\(fileName) · 파일 준비됨" : "PDF 가져오기")
                                Spacer()
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity)
                            .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(Theme.hairline))
                        }
                        .buttonStyle(.plain)
                        Text("CAD 에서 직접 출력한 벡터 PDF 를 권장한다. 스캔 이미지는 자동 판정 범위 밖이다.")
                            .font(Theme.captionFont).foregroundStyle(Theme.secondary)
                        if let importError {
                            Text(importError).font(Theme.captionFont).foregroundStyle(Theme.color(.red))
                        }
                    }
                    .card()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("또는 시연용 샘플 도면").font(.system(size: 15, weight: .semibold))
                        ForEach(SamplePlan.all) { s in
                            Button {
                                choose(sample: s)
                            } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: sampleID == s.id ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.title).font(Theme.bodyFont)
                                        Text(s.summary).font(Theme.captionFont).foregroundStyle(Theme.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .card()

                    Button("검토 만들기", action: create)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(pdf == nil)
                    if pdf == nil {
                        Text("도면을 선택하면 만들 수 있다.").font(Theme.captionFont).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("새 검토")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        pdf = try Data(contentsOf: url)
                        fileName = url.lastPathComponent
                        sampleID = nil
                        importError = nil
                        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                    } catch {
                        importError = "파일을 읽지 못했다."
                    }
                case .failure:
                    importError = "파일을 가져오지 못했다."
                }
            }
        }
    }

    private func choose(sample: SamplePlan) {
        pdf = SamplePlanRenderer.pdf(for: sample)
        fileName = "\(sample.id).pdf"
        sampleID = sample.id
        name = sample.title
    }

    private func create() {
        guard let pdf else { return }
        let project = ReviewProject(name: name.isEmpty ? fileName : name, fileName: fileName, pdfData: pdf, sampleID: sampleID)
        context.insert(project)
        try? context.save()
        onCreate(project)
        dismiss()
    }
}
