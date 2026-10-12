import SafeCertKit
import SwiftUI

/// 자동 채움 확인(U-07): 도면에서 읽은 값 + 확인 토글 + 도면에 없는 조건 입력.
struct ConfirmView: View {
    @Bindable var project: ReviewProject
    let prepared: PreparedDrawing
    let onJudge: () -> Void

    @Environment(LawStore.self) private var law
    @State private var selectedID: String?

    private var scale: ScaleEstimate? { project.effectiveScale(prepared.scaleEstimate) }
    private var plan: PlanModel { prepared.plan }

    var body: some View {
        GeometryReader { geo in
            let canvas = DrawingCanvas(pdf: project.pdfData, pageIndex: project.pageIndex, plan: plan, mode: .detected, selectedID: $selectedID)
            let form = ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    readValues
                    conditionsCard
                    judgeButton
                }
                .padding(16)
            }
            .background(Theme.background)
            if geo.size.width > geo.size.height {
                HStack(spacing: 0) {
                    canvas
                    Divider()
                    form.frame(width: min(440, geo.size.width * 0.4))
                }
            } else {
                VStack(spacing: 0) {
                    canvas.frame(height: geo.size.height * 0.42)
                    Divider()
                    form
                }
            }
        }
    }

    // MARK: 도면에서 읽은 값

    private var readValues: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("도면에서 읽은 값").font(.system(size: 15, weight: .semibold))
            if prepared.pageCount > 1 {
                Picker("페이지", selection: $project.pageIndex) {
                    ForEach(0..<prepared.pageCount, id: \.self) { Text("\($0 + 1)쪽").tag($0) }
                }
            }
            scaleRow
            Divider()
            row("영업장 바닥면적", value: area, source: scale?.confirmed == true ? "도면 계산" : nil)
            row("구획된 실", value: plan.rooms.isEmpty ? "없음" : "\(plan.rooms.count)개 · " + plan.rooms.compactMap(\.label).joined(separator: ", "), source: "도면")
            row("주된 출입구", value: doorText(plan.mainEntrances), source: "도면")
            row("비상구", value: doorText(plan.emergencyExits), source: "도면")
            ForEach(plan.notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.color(.orange))
            }
        }
        .card()
    }

    private var scaleRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("축척").font(Theme.captionFont).foregroundStyle(Theme.secondary)
                    Text(scale.map { "1:\($0.ratio)" } ?? "읽지 못함").font(.system(size: 17, weight: .semibold))
                }
                Spacer()
                if project.scaleRatioOverride == nil {
                    Toggle("확인", isOn: $project.scaleConfirmed)
                        .labelsHidden()
                        .disabled(prepared.scaleEstimate == nil)
                    Text(project.scaleConfirmed ? "확인됨" : "미확인").font(Theme.captionFont).foregroundStyle(Theme.secondary)
                }
                Menu {
                    Button("자동 추정 사용") { project.scaleRatioOverride = nil }
                    ForEach([50, 100, 150, 200, 300], id: \.self) { n in
                        Button("1:\(n) 직접 지정") { project.scaleRatioOverride = n }
                    }
                } label: {
                    Image(systemName: "pencil.circle").font(.system(size: 20))
                }
            }
            if let s = scale {
                Text("\(s.source.displayName) · " + (s.isCrossValidated ? "치수 \(s.crossChecks)개 교차검증 일치" : "교차검증 \(s.crossChecks)개 · 어긋남 \(s.conflicts)개"))
                    .font(Theme.captionFont).foregroundStyle(Theme.secondary)
            }
            if scale?.confirmed != true {
                Text("축척을 확인하기 전에는 거리·폭 판정을 하지 않는다(회색).")
                    .font(Theme.captionFont).foregroundStyle(Theme.color(.orange))
            }
        }
    }

    private var area: String {
        guard let s = scale, s.confirmed, let b = plan.boundary else { return "축척 확인 후 계산" }
        return "\(s.squareMeters(b.area).formatted(.number.precision(.fractionLength(1))))㎡"
    }

    private func doorText(_ doors: [DoorObject]) -> String {
        guard !doors.isEmpty else { return "없음" }
        return doors.map { d in
            var s = d.label ?? "\(d.id)(표기 없음 · 추정)"
            if let t = d.tag { s += " · \(t.raw)" }
            return s
        }.joined(separator: ", ")
    }

    private func row(_ label: String, value: String, source: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.captionFont).foregroundStyle(Theme.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(Theme.bodyFont).foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
            if let source { Chip(text: source) }
        }
    }

    // MARK: 조건

    private var conditionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("도면에 없는 조건").font(.system(size: 15, weight: .semibold))
            Toggle("다중이용업소 영업장", isOn: binding(\.isMultiUseBusiness))
            Picker("업종", selection: binding(\.businessType)) {
                ForEach(BusinessType.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            tri("피난층(지상 1층 등)에 있다", \.isEvacuationFloor)
            tri("2010-11-11 이전부터 영업 중인 기존 업소", \.isExistingBusiness)
            tri("영업장 안에 별도 직통계단이 있다", \.hasSeparateDirectStair)
        }
        .font(Theme.bodyFont)
        .card()
    }

    private func binding<T>(_ kp: WritableKeyPath<Conditions, T>) -> Binding<T> {
        Binding(get: { project.conditions[keyPath: kp] }, set: { project.conditions[keyPath: kp] = $0 })
    }

    private func tri(_ title: String, _ kp: WritableKeyPath<Conditions, Tri>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.captionFont).foregroundStyle(Theme.secondary)
            Picker(title, selection: binding(kp)) {
                ForEach(Tri.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: 판정

    private var judgeButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snap = law.current {
                let trusted = snap.criteria.filter { $0.status.isTrusted }.count
                Text("법령 기준일 \(snap.baseDate) · 기준 검증 통과 \(trusted)/\(snap.criteria.count)\(snap.isSeed ? " · 번들 초기값" : "")\(snap.isStale ? " · 수집 실패(이전 기준)" : "")")
                    .font(Theme.captionFont).foregroundStyle(Theme.secondary)
            }
            Button("판정 실행", action: onJudge)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(law.current == nil || law.isSyncing)
            if law.current == nil {
                Text("법령 스냅샷을 준비하는 중이다.").font(Theme.captionFont).foregroundStyle(Theme.secondary)
            } else if law.isSyncing {
                Text("오늘 법령을 실측하는 중이다.").font(Theme.captionFont).foregroundStyle(Theme.secondary)
            }
        }
    }
}
