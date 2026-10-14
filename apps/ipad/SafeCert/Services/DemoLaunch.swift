#if DEBUG
import Foundation
import SafeCertKit
import SwiftData

/// 디버그 빌드 전용 시연·화면 점검 진입점.
/// 실행 인자: `-SafeCertDemo sample-a|sample-b|sample-c` `-SafeCertDemoStep confirm|result` `-SafeCertDemoScreen law|settings`
/// `-SafeCertDemoFloor yes|no|unknown` `-SafeCertDemoSelect <판정 순번>`
/// `-SafeCertDemoFile <앱 Documents 안 PDF 이름>`(+ `-SafeCertDemoStep result` 판정까지, `-SafeCertDemoMultiUse no` 다중이용업소 아님)
/// `-SafeCertDemoStep report` = 판정 후 보고서 PDF 작성 화면까지
enum DemoLaunch {
    static var arguments: [String: String] {
        let a = ProcessInfo.processInfo.arguments
        var out: [String: String] = [:]
        for key in ["-SafeCertDemo", "-SafeCertDemoStep", "-SafeCertDemoScreen", "-SafeCertDemoFloor", "-SafeCertDemoSelect", "-SafeCertDemoFile", "-SafeCertDemoMultiUse"] {
            if let i = a.firstIndex(of: key), i + 1 < a.count { out[key] = a[i + 1] }
        }
        return out
    }

    /// 시연 대상을 준비하고 선택할 항목을 돌려준다.
    static func prepare(context: ModelContext, law: LawStore) async -> RootView.Item? {
        let args = arguments
        if let screen = args["-SafeCertDemoScreen"] {
            return screen == "law" ? .law : screen == "settings" ? .settings : nil
        }
        if let file = args["-SafeCertDemoFile"],
           let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? Data(contentsOf: docs.appendingPathComponent(file)) {
            let project = ReviewProject(name: (file as NSString).deletingPathExtension, fileName: file, pdfData: data)
            if args["-SafeCertDemoMultiUse"] == "no" { project.conditions.isMultiUseBusiness = false }
            context.insert(project)
            if ["result", "report"].contains(args["-SafeCertDemoStep"]) {
                while law.current == nil || law.isSyncing { try? await Task.sleep(for: .milliseconds(200)) }
                if let snapshot = law.current, let prepared = try? await AnalysisPipeline.prepare(pdf: data, pageIndex: 0) {
                    if let texts = prepared.recognizedTexts { project.storeRecognizedTexts(texts, page: 0) }
                    project.scaleConfirmed = true
                    let result = await AnalysisPipeline.judge(prepared, scale: project.effectiveScale(prepared.scaleEstimate),
                                                              conditions: project.conditions, snapshot: snapshot)
                    let record = AnalysisRecord(result: result)
                    record.project = project
                    context.insert(record)
                }
            }
            try? context.save()
            return .project(project.id)
        }
        guard let id = args["-SafeCertDemo"], let sample = SamplePlan.all.first(where: { $0.id == id }) else { return nil }
        // 초기값 → 당일 실측이 끝날 때까지(최대 20초) 기다린다.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, law.current == nil || law.isSyncing || (law.current?.isSeed == true && law.lastAttempt == nil) {
            try? await Task.sleep(for: .milliseconds(200))
        }

        let project = ReviewProject(name: sample.title, fileName: "\(sample.id).pdf", pdfData: SamplePlanRenderer.pdf(for: sample), sampleID: sample.id)
        project.scaleConfirmed = true
        if let floor = args["-SafeCertDemoFloor"].flatMap(Tri.init(rawValue:)) {
            project.conditions.isEvacuationFloor = floor
        }
        context.insert(project)
        if args["-SafeCertDemoStep"] != "confirm", let snapshot = law.current,
           let prepared = try? await AnalysisPipeline.prepare(pdf: project.pdfData, pageIndex: 0) {
            let result = await AnalysisPipeline.judge(prepared, scale: project.effectiveScale(prepared.scaleEstimate),
                                                      conditions: project.conditions, snapshot: snapshot)
            let record = AnalysisRecord(result: result)
            record.project = project
            context.insert(record)
        }
        try? context.save()
        return .project(project.id)
    }
}
#endif
