import SwiftUI

/// 첫 실행 안내(FR-11): 사용 순서 · 결과의 성격 · 기기 밖으로 나가는 것. 설정에서 다시 볼 수 있다.
struct GuideView: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [(icon: String, title: String, detail: String)] = [
        ("doc.badge.plus", "도면 올리기", "CAD 에서 출력한 PDF 평면도를 올린다. 시연용 샘플 도면도 있다."),
        ("ruler", "읽은 값 확인", "앱이 자동으로 읽은 축척과 조건(업종·층 등)을 확인하고 고친다."),
        ("checklist", "결과 보고 확인 체크", "도면 위 색 표시와 설명을 보고, 판정 항목마다 「확인」을 체크한다."),
        ("doc.richtext", "보고서 내보내기", "확인 여부와 AI 설명을 담은 PDF 보고서를 만들어 공유한다."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("평면도를 올리면 현행 소방 법령 기준으로 도면 위에 안전상태를 표시한다.")
                        .font(Theme.bodyFont).foregroundStyle(Theme.secondary)

                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                            HStack(alignment: .top, spacing: 14) {
                                Text("\(i + 1)")
                                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 28, height: 28).background(Theme.ink, in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Label(s.title, systemImage: s.icon).font(.system(size: 16, weight: .semibold))
                                    Text(s.detail).font(Theme.captionFont).foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                    }
                    .card()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("알아 둘 점").font(.system(size: 16, weight: .semibold))
                        note("checkmark.seal", "결과는 「감수 전 · 참고용」이다. 최종 확인은 자격 있는 전문가가 한다.")
                        note("lock", "도면과 검토 결과는 이 iPad 안에만 저장한다.")
                        note("sparkles", "보고서의 AI 문장은 판정 결과 글과 법령 조문만 Google Gemini 로 보내 만든다. 보낼 때마다 먼저 묻는다.")
                        note("bubble.left.and.text.bubble.right", "사용 의견은 왼쪽 목록의 「의견 보내기」로 보낼 수 있다.")
                    }
                    .card()

                    Button("시작하기") { dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(24)
            }
            .background(Theme.background)
            .navigationTitle("SafeCert 사용 안내")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func note(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).font(Theme.bodyFont).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.secondary)
        }
    }
}
