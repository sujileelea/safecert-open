import BackgroundTasks
import Foundation
import Observation
import SafeCertKit
import SwiftData

/// 법령 스냅샷 보관과 매일 05:00 실측 동기화.
/// iPadOS 의 백그라운드 새로고침은 정확한 시각을 보장하지 않으므로, 앱을 열 때·판정 전에
/// 당일 스냅샷이 없으면 즉시 동기화해 「매일 현행법 기준」을 보장한다.
@Observable
final class LawStore {
    static let taskID = "com.alnair.safecert.lawsync"

    private(set) var current: LawSnapshot?
    private(set) var isSyncing = false
    /// 진행 중인 실측. 다른 호출자는 새로 시작하지 않고 이것을 기다린다.
    private var syncTask: Task<Void, Never>?
    private(set) var lastAttempt: Date?
    private(set) var nextScheduled: Date?
    /// 시연용 가상 법령 변경이 켜져 있는가(앱을 다시 켜면 꺼진다).
    private(set) var demoActive = false
    private var realCurrent: LawSnapshot?
    /// 시연 중 판정에 쓴 가상 스냅샷(보고서가 다시 찾을 수 있게 보관, 저장소에는 넣지 않음).
    private var demoSnapshots: [String: LawSnapshot] = [:]

    let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    private var context: ModelContext { container.mainContext }

    var usesSampleKey: Bool { KeychainStore.lawOC == nil }

    // MARK: 시작·당일 보장

    func start() async {
        if current == nil { current = loadLatest() }
        if current == nil, let seed = await AnalysisPipeline.seedSnapshot() {
            save(seed)
            current = seed
        }
        await ensureToday()
    }

    /// 당일(KST) 실측 스냅샷이 없으면 동기화한다. 진행 중인 실측이 있으면 끝날 때까지 기다린다.
    func ensureToday() async {
        // 시연 중에는 가상 스냅샷을 유지한다(시연을 끄면 원래대로).
        if demoActive { return }
        if let syncTask {
            await syncTask.value
            return
        }
        let today = LawDate.day(Date())
        if let c = current, !c.isSeed, !c.needsRetry, c.baseDate == today {
            schedule()
            return
        }
        // 수집 실패(전면·일부) 상태면 1시간에 한 번만 다시 시도
        if let c = current, c.needsRetry, c.baseDate == today || c.isStale, let last = lastAttempt, Date().timeIntervalSince(last) < 3600 { return }
        await sync()
    }

    func sync() async {
        if let syncTask {
            await syncTask.value
            return
        }
        let task = Task { await performSync() }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func performSync() async {
        isSyncing = true
        lastAttempt = Date()
        let oc = KeychainStore.lawOC ?? LawAPIClient.sampleOC
        let snapshot = await AnalysisPipeline.dailySync(oc: oc, previous: current)
        save(snapshot)
        current = snapshot
        demoActive = false
        realCurrent = nil
        isSyncing = false
        schedule()
    }

    // MARK: 시연용 가상 법령 변경

    /// 비상구 위치 기준의 조문 문구가 바뀐 상황을 가상으로 만든다. 실제 스냅샷·저장소는 그대로다.
    func startDemoAmendment() {
        guard !demoActive, let cur = current else { return }
        let demo = cur.simulatingAmendment(of: .exitLocation)
        demoSnapshots[demo.id] = demo
        realCurrent = cur
        current = demo
        demoActive = true
    }

    func endDemoAmendment() {
        guard demoActive else { return }
        current = realCurrent ?? loadLatest()
        realCurrent = nil
        demoActive = false
    }

    /// 다음 05:00 KST 에 백그라운드 새로고침을 요청한다.
    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        let next = LawDate.nextDailyRun(after: Date())
        request.earliestBeginDate = next
        nextScheduled = next
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: 보관

    func loadLatest() -> LawSnapshot? {
        var d = FetchDescriptor<LawSnapshotRecord>(sortBy: [SortDescriptor(\.checkedAt, order: .reverse)])
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.snapshot
    }

    func snapshot(id: String) -> LawSnapshot? {
        if current?.id == id { return current }
        if let demo = demoSnapshots[id] { return demo }
        let d = FetchDescriptor<LawSnapshotRecord>(predicate: #Predicate { $0.snapshotID == id })
        return (try? context.fetch(d))?.first?.snapshot
    }

    func history(limit: Int = 30) -> [LawSnapshotRecord] {
        var d = FetchDescriptor<LawSnapshotRecord>(sortBy: [SortDescriptor(\.checkedAt, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    private func save(_ s: LawSnapshot) {
        let id = s.id
        let existing = (try? context.fetch(FetchDescriptor<LawSnapshotRecord>(predicate: #Predicate { $0.snapshotID == id }))) ?? []
        existing.forEach(context.delete)
        context.insert(LawSnapshotRecord(s))
        try? context.save()
    }
}
