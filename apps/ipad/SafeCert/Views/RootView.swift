import SafeCertKit
import SwiftData
import SwiftUI

struct RootView: View {
    enum Item: Hashable {
        case project(UUID)
        case law
        case settings
    }

    @Environment(LawStore.self) private var law
    @Environment(\.modelContext) private var context
    @Query(sort: \ReviewProject.updatedAt, order: .reverse) private var projects: [ReviewProject]

    @State private var selection: Item?
    @State private var showingNew = false
    @State private var columns: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                Section("검토") {
                    ForEach(projects) { p in
                        NavigationLink(value: Item.project(p.id)) { ProjectRow(project: p) }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(projects[i]) }
                        try? context.save()
                    }
                }
                Section("법령") {
                    NavigationLink(value: Item.law) { LawRow() }
                }
                Section {
                    NavigationLink(value: Item.settings) { Label("설정", systemImage: "gearshape") }
                }
            }
            .navigationTitle("SafeCert")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNew = true } label: { Label("새 검토", systemImage: "plus") }
                }
            }
        } detail: {
            NavigationStack {
                switch selection {
                case .project(let id):
                    if let p = projects.first(where: { $0.id == id }) {
                        ProjectView(project: p).id(p.id)
                    }
                case .law:
                    LawStatusView()
                case .settings:
                    SettingsView()
                case nil:
                    HomeView { showingNew = true }
                }
            }
        }
        .onChange(of: selection) { _, item in
            // 검토를 열면 도면에 자리를 내준다.
            if case .project = item { withAnimation { columns = .detailOnly } }
        }
        .sheet(isPresented: $showingNew) {
            NewReviewSheet { project in selection = .project(project.id) }
        }
        #if DEBUG
        .task {
            if let item = await DemoLaunch.prepare(context: context, law: law) { selection = item }
        }
        #endif
    }
}

struct ProjectRow: View {
    let project: ReviewProject

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name).font(Theme.bodyFont)
            HStack(spacing: 6) {
                if let r = project.latestAnalysis?.result {
                    ForEach(VerdictColor.allCases, id: \.self) { c in
                        if let n = r.summary.counts[c], n > 0 {
                            HStack(spacing: 2) {
                                ColorDot(color: c, size: 7)
                                Text("\(n)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                } else {
                    Text("판정 전").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct LawRow: View {
    @Environment(LawStore.self) private var law

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("법령 현황", systemImage: "books.vertical")
            if law.isSyncing {
                Text("실측 중…").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            } else if let s = law.current {
                Text("기준일 \(s.baseDate)\(s.isStale ? " · 수집 실패" : s.isSeed ? " · 초기값" : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(s.isStale ? Theme.color(.orange) : Theme.secondary)
            }
        }
    }
}

struct HomeView: View {
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.dashed.inset.filled").font(.system(size: 44)).foregroundStyle(Theme.secondary)
            Text("평면도를 올리면 현행 법령 기준으로\n도면 위에 안전상태를 표시합니다").font(Theme.titleFont).multilineTextAlignment(.center)
            Text("다중이용업소 영업장 · 벡터 PDF · 비상구 설치·위치·규격 3개 규칙 · 감수 전 참고용")
                .font(Theme.captionFont).foregroundStyle(Theme.secondary)
            Button("새 검토", action: onNew).buttonStyle(PrimaryButtonStyle()).frame(width: 240)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
