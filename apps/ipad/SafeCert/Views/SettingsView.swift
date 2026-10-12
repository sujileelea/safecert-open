import SafeCertKit
import SwiftUI

struct SettingsView: View {
    @Environment(LawStore.self) private var law
    @State private var oc = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                SecureField("발급받은 인증값(OC)", text: $oc)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("저장") {
                        KeychainStore.setLawOC(oc.trimmingCharacters(in: .whitespaces))
                        oc = ""
                        saved = true
                    }
                    Spacer()
                    Button("삭제(샘플 인증값으로)", role: .destructive) {
                        KeychainStore.setLawOC(nil)
                        saved = false
                    }
                }
                Text(law.usesSampleKey ? "현재: 공개 샘플 인증값(test) 사용 중" : "현재: 발급 인증값 사용 중(키체인 보관)")
                    .font(Theme.captionFont)
                    .foregroundStyle(law.usesSampleKey ? Theme.color(.orange) : Theme.secondary)
            } header: {
                Text("국가법령정보 공동활용 API")
            } footer: {
                Text("open.law.go.kr 에서 신청한 인증값. 값은 키체인에만 보관하고 화면에 다시 표시하지 않는다.")
            }

            Section("파일럿 범위") {
                LabeledContent("대상", value: "다중이용업소 영업장 평면도")
                LabeledContent("도면", value: "CAD 출력 벡터 PDF")
                LabeledContent("규칙", value: "비상구 설치 · 위치(이격) · 규격")
                LabeledContent("법령 실측", value: "매일 05:00 KST + 앱 실행·판정 전 보장")
                LabeledContent("판정", value: "규칙 엔진(결정적) · 감수 전 참고용")
                LabeledContent("쉬운 말 요약", value: PlainLanguageDrafter.isAvailable ? "기기 내 모델 사용 가능" : "이 기기에서 사용 불가")
                LabeledContent("버전", value: SafeCertKit.version)
            }
        }
        .navigationTitle("설정")
    }
}
