import Foundation

/// 결정적 규칙 엔진(R-03). 같은 도면·조건·축척·법령 스냅샷 → 같은 결과.
/// LLM 은 관여하지 않는다.
public enum RuleEngine {
    public struct Context: Sendable {
        public var plan: PlanModel
        public var scale: ScaleEstimate?
        public var conditions: Conditions
        public var snapshot: LawSnapshot

        public init(plan: PlanModel, scale: ScaleEstimate?, conditions: Conditions, snapshot: LawSnapshot) {
            self.plan = plan
            self.scale = scale
            self.conditions = conditions
            self.snapshot = snapshot
        }

        /// 확인 토글이 켜진 축척만 거리·폭 판정에 쓴다.
        var confirmedScale: ScaleEstimate? { scale?.confirmed == true ? scale : nil }

        func criterion(_ key: CriterionKey) -> Criterion? { snapshot.state(key)?.criterion }

        func meters(_ pts: Double) -> Double? { confirmedScale?.meters(pts) }

        var detectionConfident: Bool { plan.boundaryConfidence >= 0.9 }
    }

    public static func evaluate(_ ctx: Context) -> AnalysisResult {
        var verdicts = exitRequired(ctx) + exitLocation(ctx) + exitSize(ctx)
        verdicts = verdicts.map { applyLawStatus($0, ctx) }
        verdicts.sort { ($0.color, RuleKey.allCases.firstIndex(of: $0.rule)!, $0.id) < ($1.color, RuleKey.allCases.firstIndex(of: $1.rule)!, $1.id) }

        var counts: [VerdictColor: Int] = [:]
        for v in verdicts { counts[v.color, default: 0] += 1 }
        let needsCheck = verdicts.filter { [.gray, .orange, .yellow].contains($0.color) }.count
        let summary = AnalysisSummary(
            counts: counts,
            riskCandidates: verdicts.filter(\.color.isRiskCandidate).count,
            isReserved: needsCheck > 0,
            needsCheck: needsCheck
        )
        let area = ctx.plan.boundary.flatMap { b in ctx.confirmedScale?.squareMeters(b.area) }
        return AnalysisResult(
            verdicts: verdicts,
            summary: summary,
            snapshotID: ctx.snapshot.id,
            lawBaseDate: ctx.snapshot.baseDate,
            scale: ctx.scale,
            conditions: ctx.conditions,
            areaSquareMeters: area,
            roomCount: ctx.plan.rooms.count,
            notes: ctx.plan.notes
        )
    }

    // MARK: - 규칙 1. 비상구 설치

    static func exitRequired(_ ctx: Context) -> [Verdict] {
        let plan = ctx.plan
        var v = Verdict(
            id: "exitRequired",
            rule: .exitRequired,
            target: "영업장 전체",
            color: .gray,
            badge: .insufficient,
            summary: "",
            readValues: [],
            criteria: [],
            applicability: "",
            checkItems: [],
            lawFlags: [],
            confidence: plan.boundaryConfidence,
            location: VerdictLocation(area: plan.boundary)
        )
        guard ctx.conditions.isMultiUseBusiness else {
            v.summary = "다중이용업소가 아니라 대상 외"
            v.applicability = "다중이용업소 영업장에만 적용된다(사용자 입력: 다중이용업소 아님)."
            return [v]
        }
        v.applicability = "다중이용업소 영업장은 대통령령으로 정하는 안전시설등을 설치·유지해야 하며(법 제9조), 비상구는 그 안전시설등에 포함된다(시행령 별표 1의2 제2호)."

        guard let crit = ctx.criterion(.exitRequired) else {
            v.summary = "법령 기준 미확정 — 판정하지 않음"
            return [v]
        }
        v.criteria = [
            ReadValue("예외 가목 직통계단 이격", crit["exemptionA.ratio"]?.display ?? "-", .lawCriterion),
            ReadValue("예외 나목 바닥면적", "\(crit["exemptionB.maxArea"]?.display ?? "-") 이하", .lawCriterion),
            ReadValue("예외 나목 출입구까지 수평거리", "\(crit["exemptionB.maxDistance"]?.display ?? "-") 이하", .lawCriterion)
        ]

        // 출입구를 하나도 식별하지 못하면 「비상구 없음」으로 단정하지 않는다.
        guard !plan.exteriorDoors.isEmpty else {
            v.color = .orange
            v.badge = .expertCheck
            v.summary = "출입구를 식별하지 못함 — 판정 보류"
            v.readValues.append(ReadValue("외부 출입문", "식별 못 함", .drawingExtracted))
            v.checkItems.append("도면에서 문(문짝 선 + 열림 궤적)을 찾지 못했다. 문이 그려진 CAD 출력 PDF 인지, 주출입구·비상구 표기가 있는지 확인한다.")
            return [v]
        }

        let exits = plan.emergencyExits
        v.readValues.append(ReadValue("비상구", exits.isEmpty ? "없음" : exits.map { $0.label ?? $0.id }.joined(separator: ", "), .drawingExtracted))
        v.readValues.append(ReadValue("주된 출입구", plan.mainEntrances.isEmpty ? "미식별" : plan.mainEntrances.map { $0.label ?? $0.id }.joined(separator: ", "), .drawingExtracted))
        v.location.markers = exits.map(\.center) + plan.mainEntrances.map(\.center)

        if !exits.isEmpty {
            let confident = exits.allSatisfy { $0.roleConfidence >= 0.9 }
            v.color = confident ? .green : .orange
            v.badge = confident ? .autoConfirmed : .expertCheck
            v.confidence = min(plan.boundaryConfidence, exits.map(\.roleConfidence).min() ?? 0)
            v.summary = confident ? "비상구 \(exits.count)개 확인" : "비상구로 추정되는 문 \(exits.count)개 — 표기 확인 필요"
            if !confident { v.checkItems.append("도면에 「비상구」 표기가 없어 폭으로 역할을 추정했다. 비상구 여부를 확인한다.") }
            v.checkItems.append("비상구가 직통계단·피난계단·옥외피난계단 또는 발코니에 연결되는지 확인한다(시행령 별표 1의2 비고 2).")
            return [v]
        }

        // 비상구 없음 → 예외 검토
        var undecided: [String] = []
        var exempt: String?

        // 예외 나목: 피난층 + 면적 + 구획된 실 없음 + 각 부분에서 출입구까지 수평거리
        switch ctx.conditions.isEvacuationFloor {
        case .no:
            v.readValues.append(ReadValue("피난층 여부", "아니오", .userInput))
        case .unknown:
            v.readValues.append(ReadValue("피난층 여부", "모름", .userInput))
            undecided.append("영업장이 피난층에 있는지 입력이 필요하다(예외 나목).")
        case .yes:
            v.readValues.append(ReadValue("피난층 여부", "예", .userInput))
            if let boundary = plan.boundary, let scale = ctx.confirmedScale,
               let maxArea = crit["exemptionB.maxArea"]?.number, let maxDist = crit["exemptionB.maxDistance"]?.number {
                let area = scale.squareMeters(boundary.area)
                let perimeter = scale.meters(boundary.edges.reduce(0) { $0 + $1.length })
                let farthest = farthestDistance(in: boundary, to: plan.exteriorDoors.map(\.center), scale: scale)
                // 경계 허용 폭: 면적 = 둘레 × 작도 오차, 거리 = 작도 오차 2배(최소 5cm)
                let areaTol = perimeter * scale.resolutionMeters
                let distTol = max(scale.resolutionMeters * 2, 0.05)
                v.readValues.append(ReadValue("영업장 바닥면적", fmt(area, "㎡"), .drawingComputed))
                v.readValues.append(ReadValue("구획된 실", plan.rooms.isEmpty ? "없음" : "\(plan.rooms.count)개", .drawingComputed))
                v.readValues.append(ReadValue("가장 먼 부분 → 출입구 수평거리", fmt(farthest, "m"), .drawingComputed))
                let clearlyOut = !plan.rooms.isEmpty || area > maxArea + areaTol || farthest > maxDist + distTol
                let clearlyIn = plan.rooms.isEmpty && area <= maxArea - areaTol && farthest <= maxDist - distTol
                if clearlyOut && ctx.detectionConfident {
                    // 예외 나목 비해당(확정)
                } else if clearlyIn && ctx.detectionConfident {
                    exempt = "피난층·바닥면적 \(fmt(area, "㎡"))·구획된 실 없음·최대 수평거리 \(fmt(farthest, "m")) — 예외 나목 해당"
                } else if !ctx.detectionConfident {
                    undecided.append("영업장 외곽선을 추정했다(벽이 닫히지 않음). 면적·구획된 실을 확인해야 예외 나목을 판단할 수 있다.")
                } else {
                    undecided.append("면적 \(fmt(area, "㎡"))·수평거리 \(fmt(farthest, "m"))가 예외 나목 기준의 도면 오차 범위 안이다. 현장 실측으로 확인한다.")
                }
            } else {
                undecided.append("축척이 확인되지 않아 예외 나목(면적·수평거리)을 계산하지 못했다.")
            }
        }

        // 예외 가목: 별도 직통계단
        v.readValues.append(ReadValue("별도 직통계단", ctx.conditions.hasSeparateDirectStair.displayName, .userInput))
        v.readValues.append(ReadValue("기존 업소(고시 기준일 이전 영업)", ctx.conditions.isExistingBusiness.displayName, .userInput))
        switch ctx.conditions.hasSeparateDirectStair {
        case .yes: undecided.append("별도 직통계단이 있다고 입력됐다. 주된 출입구 중심선에서 긴 변 길이의 \(crit["exemptionA.ratio"]?.literal ?? "기준 비율") 이상 떨어져 있는지 확인한다(예외 가목).")
        case .unknown: undecided.append("별도 직통계단 유무 입력이 필요하다(예외 가목).")
        case .no: break
        }

        // 기존 업소 고시
        switch ctx.conditions.isExistingBusiness {
        case .yes:
            let date = ctx.criterion(.existingExemption)?["cutoffDate"]?.literal ?? "기준일"
            undecided.append("\(date) 이전부터 영업한 기존 업소로 입력됐다. 소방청 고시의 「건축물 구조상 비상구를 설치할 수 없는 경우」 해당 여부를 확인한다.")
        case .unknown: undecided.append("기존 업소(고시 기준일 이전 영업) 여부 입력이 필요하다.")
        case .no: break
        }

        if let exempt {
            v.color = .green
            v.badge = ctx.detectionConfident ? .autoConfirmed : .expertCheck
            v.summary = "비상구 없음 · " + exempt
            v.checkItems.append("영업장 전체가 개방된 구조인지 현장에서 확인한다.")
        } else if !undecided.isEmpty {
            v.color = .orange
            v.badge = ctx.conditions.isExistingBusiness == .yes || ctx.conditions.hasSeparateDirectStair == .yes ? .fieldCheck : .insufficient
            v.summary = "비상구 없음 · 예외 해당 여부 확인 필요"
            v.checkItems += undecided
        } else {
            v.color = ctx.detectionConfident ? .red : .orange
            v.badge = ctx.detectionConfident ? .autoConfirmed : .expertCheck
            v.summary = "비상구 없음 · 예외(가목·나목·고시) 비해당"
            v.checkItems.append("주된 출입구 외에 비상구를 설치해야 한다. 미이행 시 소방본부장·소방서장의 보완 등 조치명령 또는 영업정지·허가취소 요청 대상이 될 수 있다(법 제9조제2항).")
        }
        return [v]
    }

    // MARK: - 규칙 2. 비상구 위치(이격거리)

    static func exitLocation(_ ctx: Context) -> [Verdict] {
        let plan = ctx.plan
        guard ctx.conditions.isMultiUseBusiness else { return [] }
        let exits = plan.emergencyExits
        let applicability = "비상구는 주된 출입구의 반대방향에, 주된 출입구 중심선으로부터 영업장의 가장 긴 대각선·가로·세로 길이 중 가장 긴 길이의 기준 비율 이상 떨어진 위치에 설치해야 한다(시행규칙 별표 2 제2호가목1)."
        guard !exits.isEmpty else {
            return [Verdict(id: "exitLocation", rule: .exitLocation, target: "비상구", color: .gray, badge: .insufficient,
                            summary: "비상구가 없어 위치를 판정하지 않음", readValues: [], criteria: [], applicability: applicability,
                            checkItems: [], lawFlags: [], confidence: plan.boundaryConfidence, location: VerdictLocation())]
        }
        let crit = ctx.criterion(.exitLocation)
        let ratio = crit?["ratio"]
        let main = plan.mainEntrances.first

        return exits.map { exit in
            var v = Verdict(id: "exitLocation.\(exit.id)", rule: .exitLocation, target: "\(exit.label ?? "비상구") (\(exit.id))",
                            color: .gray, badge: .insufficient, summary: "", readValues: [], criteria: [], applicability: applicability,
                            checkItems: [], lawFlags: [], confidence: min(plan.boundaryConfidence, exit.roleConfidence),
                            location: VerdictLocation(markers: [exit.center]))
            if let ratio { v.criteria = [ReadValue("이격 비율", ratio.literal, .lawCriterion)] }
            guard let ratio else {
                v.summary = "법령 기준 미확정 — 판정하지 않음"
                return v
            }
            guard let main, let boundary = plan.boundary else {
                v.color = .orange
                v.badge = .expertCheck
                v.summary = "주된 출입구를 식별하지 못해 거리를 계산하지 못함"
                v.checkItems.append("도면에 「주출입구」 표기를 확인한다.")
                return v
            }
            v.location.markers = [main.center, exit.center]
            v.location.line = Segment(main.center, exit.center)
            guard let scale = ctx.confirmedScale else {
                v.summary = "축척 미확정 — 거리 판정하지 않음"
                v.checkItems.append("축척을 확인하면 판정한다.")
                return v
            }
            let b = boundary.bounds
            let longest = max(boundary.diameter, b.width, b.height)
            let L = scale.meters(longest)
            let d = scale.meters(main.center.distance(to: exit.center))
            let required = ratio.number * L
            let tol = max(scale.resolutionMeters * 2, 0.05)

            // 반대방향 여부: 영업장 중심에서 본 두 문 방향의 사잇각
            let c = boundary.centroid
            let a1 = (main.center - c).normalized, a2 = (exit.center - c).normalized
            let angle = acos(max(-1, min(1, a1.dot(a2)))) * 180 / .pi
            // 반대방향: 135° 이상만 자동 인정, 90~135° 는 확인 필요, 90° 미만은 같은 쪽.
            let opposite = angle >= 135
            let ambiguousSide = angle >= 90 && angle < 135

            v.readValues = [
                ReadValue("주된 출입구 중심 ↔ 비상구 중심 수평거리", fmt(d, "m"), .drawingComputed),
                ReadValue("영업장 가장 긴 길이(대각선·가로·세로 중 최대)", fmt(L, "m"), .drawingComputed),
                ReadValue("방향(영업장 중심 기준 사잇각)", "\(Int(angle.rounded()))° · \(opposite ? "반대편" : ambiguousSide ? "측면" : "같은 쪽")", .drawingComputed)
            ]
            v.criteria.append(ReadValue("필요 이격거리", "\(fmt(required, "m")) 이상 (\(fmt(L, "m")) × \(ratio.literal))", .lawCriterion))
            let rolesConfident = main.roleConfidence >= 0.9 && exit.roleConfidence >= 0.9 && ctx.detectionConfident

            if d < required - tol {
                v.color = rolesConfident ? .red : .orange
                v.badge = rolesConfident ? .autoConfirmed : .expertCheck
                v.summary = "이격거리 \(fmt(d, "m")) < 기준 \(fmt(required, "m"))"
                v.checkItems.append("비상구를 주된 출입구에서 기준 이상 떨어진 위치(반대방향)로 옮기는 설계 검토가 필요하다.")
            } else if d < required + tol {
                v.color = .orange
                v.badge = .fieldCheck
                v.summary = "이격거리 \(fmt(d, "m")) ≈ 기준 \(fmt(required, "m")) — 경계값"
                v.checkItems.append("도면 해상도 오차(±\(fmt(tol, "m"))) 안의 경계값이다. 현장 실측으로 확인한다.")
            } else if !opposite {
                v.color = .orange
                v.badge = .expertCheck
                v.summary = "이격거리 충족(\(fmt(d, "m")) ≥ \(fmt(required, "m"))) · " + (ambiguousSide ? "반대방향 여부 확인 필요" : "반대방향 아님")
                v.checkItems.append("반대방향이 아닌 설치는 건물구조상 반대방향에 설치할 수 없는 경우에만 허용된다(같은 호 단서). 사유를 확인한다.")
            } else {
                v.color = rolesConfident ? .green : .orange
                v.badge = rolesConfident ? .autoConfirmed : .expertCheck
                v.summary = "이격거리 \(fmt(d, "m")) ≥ 기준 \(fmt(required, "m")) · 반대편"
            }
            v.checkItems.append("거리는 두 출입구 중심점 사이 직선거리로 계산했다(「중심선으로부터의 수평거리」 해석).")
            return v
        }
    }

    // MARK: - 규칙 3. 비상구등 규격

    static func exitSize(_ ctx: Context) -> [Verdict] {
        let plan = ctx.plan
        guard ctx.conditions.isMultiUseBusiness else { return [] }
        let crit = ctx.criterion(.exitSize)
        let applicability = "주된 출입구와 비상구(비상구등)는 문틀을 제외한 가로·세로 길이가 기준 이상이어야 한다(시행규칙 별표 2 제2호가목2)."
        return plan.exteriorDoors.map { door in
            var v = Verdict(id: "exitSize.\(door.id)", rule: .exitSize, target: "\(door.label ?? door.role.displayName) (\(door.id))",
                            color: .gray, badge: .insufficient, summary: "", readValues: [], criteria: [], applicability: applicability,
                            checkItems: [], lawFlags: [], confidence: door.roleConfidence,
                            location: VerdictLocation(markers: [door.center], line: door.chord))
            guard let minW = crit?["minWidth"], let minH = crit?["minHeight"] else {
                v.summary = "법령 기준 미확정 — 판정하지 않음"
                return v
            }
            v.criteria = [ReadValue("최소 가로(문틀 제외)", minW.display, .lawCriterion), ReadValue("최소 세로(문틀 제외)", minH.display, .lawCriterion)]

            var widthCM: Double?
            var tol = 0.0
            if let tag = door.tag {
                widthCM = Double(tag.widthMM) / 10
                v.readValues.append(ReadValue("가로", "\(fmt(Double(tag.widthMM) / 10, "cm")) (표기 \(tag.raw))", .drawingExtracted))
                v.checkItems.append("표기 치수가 문틀을 제외한 유효 치수인지 확인한다.")
            } else if let m = ctx.meters(door.openingWidth) {
                widthCM = m * 100
                tol = (ctx.confirmedScale?.resolutionMeters ?? 0) * 100
                v.readValues.append(ReadValue("가로", "\(fmt(m * 100, "cm")) (문짝 길이)", .drawingComputed))
            } else {
                v.readValues.append(ReadValue("가로", "축척 미확정", .drawingComputed))
            }
            let heightCM = door.tag.map { Double($0.heightMM) / 10 }
            v.readValues.append(ReadValue("세로", heightCM.map { fmt($0, "cm") } ?? "평면도에 표기 없음", heightCM == nil ? .drawingComputed : .drawingExtracted))

            guard let w = widthCM else {
                v.summary = "축척 미확정 · 규격 표기 없음 — 판정하지 않음"
                v.checkItems.append("축척을 확인하거나 문 규격 표기가 있는 도면이 필요하다.")
                return v
            }
            // 빨강은 역할(주된 출입구·비상구)이 표기로 확인된 문에만. 규격 표기는 치수를 확인할 뿐 역할을 확인하지 않는다.
            let detection = door.roleConfidence >= 0.9
            if w < minW.number - tol {
                v.color = detection ? .red : .orange
                v.badge = door.tag != nil ? .autoConfirmed : (ctx.scale?.isCrossValidated == true ? .autoConfirmed : .expertCheck)
                v.summary = "가로 \(fmt(w, "cm")) < 기준 \(minW.display)"
                v.checkItems.append("문 폭을 기준 이상으로 넓히는 설계 검토가 필요하다.")
            } else if w < minW.number + tol {
                v.color = .orange
                v.badge = .fieldCheck
                v.summary = "가로 \(fmt(w, "cm")) ≈ 기준 \(minW.display) — 경계값"
                v.checkItems.append("도면 해상도 오차 안의 경계값이다. 문틀 제외 유효폭을 현장 실측한다.")
            } else if let h = heightCM {
                if h < minH.number {
                    v.color = detection ? .red : .orange
                    v.badge = detection ? .autoConfirmed : .expertCheck
                    v.summary = "세로 \(fmt(h, "cm")) < 기준 \(minH.display)"
                } else {
                    v.color = .green
                    v.badge = .autoConfirmed
                    v.summary = "가로 \(fmt(w, "cm")) · 세로 \(fmt(h, "cm")) ≥ 기준 \(minW.display) · \(minH.display)"
                }
            } else {
                v.color = .orange
                v.badge = .fieldCheck
                v.summary = "가로 \(fmt(w, "cm")) 충족 · 세로 미확인"
                v.checkItems.append("평면도에는 문 높이가 없다. 세로 \(minH.display) 이상인지 입면도·현장에서 확인한다.")
            }
            return v
        }
    }

    // MARK: - 법령 상태 반영

    static func applyLawStatus(_ verdict: Verdict, _ ctx: Context) -> Verdict {
        var v = verdict
        let snap = ctx.snapshot
        var colorOverride = false
        for key in v.rule.criteria {
            // 기존 업소 고시는 기존 업소로 입력된 경우에만 영향
            if key == .existingExemption && ctx.conditions.isExistingBusiness != .yes { continue }
            guard let st = snap.state(key) else { continue }
            switch st.status {
            case .rejected:
                v.lawFlags.append(.criterionUnverified(st.note ?? key.displayName))
                colorOverride = true
            case .interpretationChanged:
                v.lawFlags.append(.interpretationChanged(st.note ?? key.displayName))
                colorOverride = true
            case .unavailable:
                if !v.lawFlags.contains(.criterionUnavailable) { v.lawFlags.append(.criterionUnavailable) }
            case .verified:
                if snap.isRecentlyRevised(key), let d = st.revisedOn { v.lawFlags.append(.recentlyRevised(d)) }
            }
        }
        if colorOverride && v.color != .gray {
            v.color = .yellow
            v.badge = .expertCheck
            v.summary = "기준 변경 감지 — 이전 기준으로 계산한 결과: " + v.summary
        }
        // 공포 후 미시행 개정(같은 법령 계열)
        for p in snap.pendingAmendments { v.lawFlags.append(.pendingAmendment(lawName: p.lawName, effectiveDate: p.effectiveDate)) }
        if snap.isStale {
            v.lawFlags.append(.staleSnapshot(baseDate: snap.baseDate))
        } else {
            for c in snap.carriedClauses where v.rule.clauses.contains(c.key) {
                v.lawFlags.append(.clauseCarried(citation: c.citation, collectedOn: c.collectedOn ?? "-"))
            }
        }
        for e in snap.events where e.kind == .noticeListChanged && e.subject.contains("비상구") {
            v.lawFlags.append(.relatedNoticeChanged(e.subject))
        }
        return v
    }

    /// 영업장 각 부분에서 가장 가까운 출입구까지의 수평거리 중 최댓값(m).
    /// 꼭짓점·변 표본 + 내부 격자(약 0.25m, 최대 약 4천 점)로 잰다.
    static func farthestDistance(in polygon: Polygon, to doors: [Point], scale: ScaleEstimate) -> Double {
        guard !doors.isEmpty else { return .infinity }
        let b = polygon.bounds
        let step = max(0.25 / scale.metersPerPoint, (b.width * b.height / 4000).squareRoot())
        var samples = polygon.vertices
        for e in polygon.edges {
            let n = max(1, Int(e.length / step))
            for i in 0..<n { samples.append(e.a + (e.b - e.a) * (Double(i) / Double(n))) }
        }
        var y = b.minY + step / 2
        while y < b.maxY {
            var x = b.minX + step / 2
            while x < b.maxX {
                let p = Point(x, y)
                if polygon.contains(p) { samples.append(p) }
                x += step
            }
            y += step
        }
        let worst = samples.map { p in doors.map { $0.distance(to: p) }.min()! }.max() ?? .infinity
        return scale.meters(worst)
    }

    static func fmt(_ value: Double, _ unit: String) -> String {
        "\(value.formatted(.number.precision(.fractionLength(unit == "cm" ? 0...0 : 1...2)).locale(Locale(identifier: "ko_KR"))))\(unit)"
    }
}
