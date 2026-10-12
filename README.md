# SafeCert

건축·소방 평면도를 분석해 현행 법령 기준의 안전상태를 도면 위 색으로 표시하고, 근거와 설명을 함께 보여주는 소프트웨어.

## 현재 단계 — 사전 파일럿 (MVP 전)

- 범위: 다중이용업소 영업장 **벡터 PDF 평면도** 업로드 → 규칙 3개 결정적 판정 → 도면 위 5색 + 별도 텍스트 설명
- 법령: 매일 05:00 KST 국가법령정보 공동활용 API 실측 → 조문 정규화(코드 파서 2종) → 코드 검증 5종 → 법령 스냅샷
- 형태: **iPad 전용 네이티브 앱** — SwiftUI · SwiftData · Apple 퍼스트파티 프레임워크만 사용(외부 의존성 0)
- 표시: 전 화면 「감수 전·참고용」. 운영자 대행 시연용이며 자문 검수 전이다.

## 구조

| 경로 | 내용 |
|---|---|
| `packages/SafeCertKit` | 순수 로직 Swift 패키지 — 기하 · 벡터 PDF 해석 · 평면 해석 · 축척 · 법령 수집·정규화·검증 · 규칙 엔진 · 설명 |
| `packages/SafeCertKit/Sources/SafeCertKit/Resources/LawSeed` | 법령 초기값(2026-10-12 API 응답 녹화). 첫 실행·오프라인 기준 |
| `apps/ipad` | iPad 앱(SwiftUI · SwiftData). `SafeCertKit` 을 로컬 패키지로 사용 |

## 빌드·시험

```sh
# 로직 시험 (macOS)
cd packages/SafeCertKit && swift test

# iPad 앱 빌드 (시뮬레이터)
cd apps/ipad && xcodebuild -project SafeCert.xcodeproj -scheme SafeCert \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

요구: Xcode 27 · iPadOS 26 이상.

## 브랜치

`main` = 배포 버전만 · `develop` = 개발. `main` 병합은 배포 결정이다.
