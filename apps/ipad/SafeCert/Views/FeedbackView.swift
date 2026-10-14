import SafeCertKit
import SwiftUI

/// 의견 보내기(FR-12): 짧은 설문을 글로 묶어 메일·메시지 등 사용자가 고른 방법으로 보낸다.
/// 앱은 의견을 따로 저장하거나 서버로 보내지 않는다.
struct FeedbackView: View {
    enum Role: String, CaseIterable {
        case designer = "인테리어·설계 실무자"
        case fireContractor = "소방시설 업체"
        case founder = "창업 예정자"
        case other = "기타"
    }

    @State private var role: Role = .designer
    @State private var overall = 0
    @State private var clarity = 0
    @State private var good = ""
    @State private var improve = ""

    var body: some View {
        Form {
            Section("나에 대해") {
                Picker("역할", selection: $role) {
                    ForEach(Role.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            Section("점수 (1 = 매우 아니다 · 5 = 매우 그렇다)") {
                score("전체적으로 쓸 만하다", $overall)
                score("판정 결과와 설명을 이해하기 쉬웠다", $clarity)
            }
            Section("좋았던 점") {
                TextEditor(text: $good).frame(minHeight: 80)
            }
            Section("불편했던 점 · 고칠 점") {
                TextEditor(text: $improve).frame(minHeight: 80)
            }
            Section {
                ShareLink(item: message, subject: Text("SafeCert 사용 의견")) {
                    Label("의견 보내기", systemImage: "paperplane")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(overall == 0 && clarity == 0 && good.isEmpty && improve.isEmpty)
            } footer: {
                Text("메일·메시지 등 편한 방법을 골라 보낸다. 이름·연락처는 적지 않아도 된다. 도면은 함께 보내지 않는다.")
            }
        }
        .navigationTitle("의견 보내기")
    }

    private func score(_ title: String, _ value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.bodyFont)
            Picker(title, selection: value) {
                Text("-").tag(0)
                ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }

    /// 보낼 글. 앱 버전을 붙여 어떤 빌드에 대한 의견인지 알 수 있게 한다.
    var message: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return """
        [SafeCert 사용 의견]
        역할: \(role.rawValue)
        전체적으로 쓸 만하다: \(overall == 0 ? "-" : "\(overall) / 5")
        판정 결과·설명 이해: \(clarity == 0 ? "-" : "\(clarity) / 5")
        좋았던 점: \(good.isEmpty ? "-" : good)
        불편했던 점·고칠 점: \(improve.isEmpty ? "-" : improve)
        앱 버전: \(version) (\(build))
        """
    }
}
