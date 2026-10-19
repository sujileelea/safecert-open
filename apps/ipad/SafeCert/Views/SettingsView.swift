import SafeCertKit
import SwiftUI

struct SettingsView: View {
    @Environment(LawStore.self) private var law
    @State private var oc = ""
    @State private var saved = false
    @State private var geminiKey = ""
    @State private var hasGeminiKey = KeychainStore.geminiKey != nil

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

            Section {
                SecureField("Gemini API 키", text: $geminiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("저장") {
                        KeychainStore.setGeminiKey(geminiKey.trimmingCharacters(in: .whitespaces))
                        geminiKey = ""
                        hasGeminiKey = KeychainStore.geminiKey != nil
                    }
                    Spacer()
                    Button("삭제", role: .destructive) {
                        KeychainStore.setGeminiKey(nil)
                        hasGeminiKey = false
                    }
                }
                Text(hasGeminiKey ? "현재: 키 저장됨(키체인 보관) — 보고서·쉬운 말 요약에 AI 문장 사용" : "현재: 키 없음 — 보고서는 규칙 엔진 문장으로만 작성")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.secondary)
            } header: {
                Text("생성형 AI(Google Gemini · 무료 티어)")
            } footer: {
                Text("보고서 문장을 쓸 때 판정 결과 글과 법령 조문만 보낸다. 도면 파일·이미지·검토 이름은 보내지 않는다. 무료 티어는 입력이 Google 제품 개선에 쓰일 수 있어, 보낼 때마다 확인을 받는다.")
            }

            Section {
                Toggle("법령 변경 시연(가상)", isOn: Binding(
                    get: { law.demoActive },
                    set: { $0 ? law.startDemoAmendment() : law.endDemoAmendment() }
                ))
            } header: {
                Text("시연")
            } footer: {
                Text("「비상구 위치」 기준의 조문 문구가 바뀐 상황을 가상으로 만든다. 켠 뒤 결과 화면에서 「최신 법령으로 다시 판정」을 누르면 해당 항목이 노랑(기준 변경 감지)으로 바뀐다. 실제 법령과 무관하며, 끄거나 앱을 다시 켜면 원래대로 돌아간다.")
            }

            Section("파일럿 범위") {
                LabeledContent("대상", value: "다중이용업소 영업장 평면도")
                LabeledContent("도면", value: "CAD 출력 벡터 PDF")
                LabeledContent("규칙", value: "비상구 설치 · 위치(이격) · 규격")
                LabeledContent("법령 실측", value: "매일 05:00 KST + 앱 실행·판정 전 보장")
                LabeledContent("판정", value: "규칙 엔진(결정적) · 감수 전 참고용")
                LabeledContent("생성형 AI", value: hasGeminiKey ? "Gemini \(GeminiClient.defaultModel)" : "키 없음")
                LabeledContent("버전", value: SafeCertKit.version)
            }
        }
        .navigationTitle("설정")
    }
}
