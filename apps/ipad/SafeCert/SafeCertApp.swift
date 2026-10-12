import SafeCertKit
import SwiftData
import SwiftUI

@main
struct SafeCertApp: App {
    let container: ModelContainer
    @State private var law: LawStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: ReviewProject.self, AnalysisRecord.self, LawSnapshotRecord.self)
        } catch {
            fatalError("저장소를 열 수 없다: \(error)")
        }
        self.container = container
        _law = State(initialValue: LawStore(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(law)
                .preferredColorScheme(.light)
                .task { await law.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await law.ensureToday() } }
                }
        }
        .modelContainer(container)
        .backgroundTask(.appRefresh(LawStore.taskID)) {
            await law.sync()
        }
    }
}
