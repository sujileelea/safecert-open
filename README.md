# SafeCert

건축·소방 평면도를 분석해 현행 법령 기준의 안전상태를 도면 위 색으로 표시하고, 근거와 설명을 함께 보여주는 소프트웨어.

## 현재 단계 — 사전 파일럿 (MVP 전)

| 항목 | 내용 |
|---|---|
| 형태 | **iPad 전용 네이티브 앱** — SwiftUI · SwiftData · Apple 퍼스트파티 프레임워크만(외부 의존성 0, 서버 없음) |
| 대상 | 다중이용업소 영업장 평면도 · CAD 에서 출력한 **벡터 PDF** |
| 규칙 | 비상구 설치(시행령 별표 1의2 제2호·고시) · 비상구 위치 이격(시행규칙 별표 2 제2호가목1) · 비상구등 규격(같은 목 2) |
| 법령 | 매일 05:00 KST 국가법령정보 공동활용 API 실측 → 조문 정규화(독립 코드 파서 2종) → 코드 검증 5종 → 법령 스냅샷. 앱 실행·판정 직전에 당일 스냅샷이 없으면 즉시 실측 |
| 판정 | 결정적 규칙 엔진. LLM 불관여. 판단 불가 항목은 초록 금지 |
| 설명 | 판정 상세 7단 + 조문 원문(그날 스냅샷) 직접 삽입. 「쉬운 말 요약」은 기기 내 모델(FoundationModels) 초안 · 사실 대조 실패 시 폐기 |
| 표시 | 전 화면 「감수 전·참고용」. 운영자 대행 시연용 |

### 색과 법령 상태

| 색 | 의미 |
|---|---|
| 빨강 | 의무 미충족 |
| 주황 | 위반 가능성 · 확인 필요(경계값·표기 없음·예외 확인 등) |
| 노랑 | 기준 변경 감지 — 자동 검증 실패 또는 조문 문구(해석) 변경 시, 이전 기준으로 계산한 결과에 표시 |
| 초록 | 확인 범위 내 적합 |
| 회색 | 자료 부족 · 대상 외(축척 미확정 등) |

코드 검증 5종: ① 형식 ② 원문 근거(뽑은 숫자가 원문에 숫자 경계째 있고, 원문 글자로 다시 계산한 값과 같은가) ③ 이중 정규화 일치 ④ 변화 폭 ⑤ 회귀(샘플 도면 재판정 — 무관 규칙 불변 + 엄격화·완화 방향 일관).
통과 = 새 값 반영(30일 「최근 개정」 표시) · 실패 = 이전 값 유지 + 노랑 · 문구 변경 = 자동 반영 안 함 + 노랑(원래 문구로 돌아오면 복귀) · 전면 수집 실패 = 전날 스냅샷 + 기준일 경고 · 일부 수집 실패 = 해당 조문 이전 수집본 + 「일부 수집 실패」 표식, 1시간 간격 재시도.

## 구조

| 경로 | 내용 |
|---|---|
| `packages/SafeCertKit` | 순수 로직 Swift 패키지(iOS·macOS 26) |
| ├ `Geometry` | 점·선분·다각형·원호 맞춤·평면 그래프 면 추출 |
| ├ `Drawing` | 벡터 PDF 해석(CGPDFScanner·PDFKit) · 페이지 렌더러 |
| ├ `Plan` | 평면 해석(벽·문·외곽·실·출입구 역할·문 규격) · 축척 추정 |
| ├ `Law` | 법령 API · 응답 해석 · 조문 추출 · 정규화 · 코드 검증 · 스냅샷 |
| ├ `Rules` | 규칙 엔진 · 조건 · 판정 모델 · 회귀 세트 |
| ├ `Explain` | 판정 설명 7단 · 쉬운 말 초안 |
| ├ `Samples` | 시연용 샘플 도면 3종(CoreGraphics 생성) |
| └ `Resources/LawSeed` | 법령 초기값(2026-10-12 API 응답 녹화). 첫 실행·오프라인 기준 |
| `apps/ipad` | iPad 앱(SwiftUI · SwiftData · BackgroundTasks · Security) |

## 빌드·시험

```sh
# 로직 시험 (macOS) — 58개
cd packages/SafeCertKit && swift test

# iPad 앱 빌드 (시뮬레이터)
cd apps/ipad && xcodebuild -project SafeCert.xcodeproj -scheme SafeCert \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

요구: Xcode 27 · iPadOS 26 이상. 쉬운 말 요약은 Apple Intelligence 지원 기기에서만 보인다.

### 시연 실행 인자 (디버그 빌드 전용)

| 인자 | 동작 |
|---|---|
| `-SafeCertDemo sample-a\|sample-b\|sample-c` | 샘플 검토를 만들고(축척 확인) 판정까지 진행 |
| `-SafeCertDemoStep confirm` | 판정 전 확인 단계에서 멈춤 |
| `-SafeCertDemoFloor yes\|no\|unknown` | 피난층 조건 |
| `-SafeCertDemoSelect N` | N번째 판정 상세를 펼침 |
| `-SafeCertDemoScreen law\|settings` | 법령 현황·설정 화면 |

## 법령 API 인증값

`open.law.go.kr` 에서 신청한 인증값(OC)을 앱 설정에 넣으면 키체인에 보관한다. 없으면 공개 샘플 인증값(`test`)으로 호출하며 화면에 경고가 뜬다 — 운영 전 교체 필요.

## 브랜치

`main` = 배포 버전만 · `develop` = 개발. `main` 병합은 배포 결정이다.
