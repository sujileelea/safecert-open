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
    private(set) var lastAttempt: Date?
    private(set) var nextScheduled: Date?

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

    /// 당일(KST) 실측 스냅샷이 없으면 동기화한다.
    func ensureToday() async {
        guard !isSyncing else { return }
        let today = LawDate.day(Date())
        if let c = current, !c.isSeed, !c.isStale, c.baseDate == today {
            schedule()
            return
        }
        // 수집 실패 상태면 1시간에 한 번만 다시 시도
        if let c = current, c.isStale, let last = lastAttempt, Date().timeIntervalSince(last) < 3600 { return }
        await sync()
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastAttempt = Date()
        let oc = KeychainStore.lawOC ?? LawAPIClient.sampleOC
        let snapshot = await AnalysisPipeline.dailySync(oc: oc, previous: current)
        save(snapshot)
        current = snapshot
        isSyncing = false
        schedule()
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
