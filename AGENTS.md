# Project

개인용 네이티브 iOS YouTube Music 클라이언트. SwiftUI로 개발한다.
승인된 SwiftUI prototype(T1 Home/Library + native Search, H1 Quick Picks 우선, P1 Mini/P3 Full Player)에 실제 YouTube Music 데이터를 단계적으로 연결하는 중이다. 진행 상황과 검증 근거는 `Spikes/HANDOFF.md`를 따른다.

- InnerTube networking, 사용자 본인 browser session 기반 auth, browse/search/library data integration은 허용된 작업이다. credential·session 파일과 녹화 응답은 저장소 밖에 두고 commit하지 않는다. UI/domain은 인증 구현을 직접 알지 않는다.
- Playback/streaming은 production 앱에 바로 결합하지 않는다. 별도 spike(`Spikes/`)에서 연구하고, 검증된 뒤에만 앱 연결을 제안한다.
- signature/n, PO Token, SABR, 페이지 동작 무력화 등 보호·anti-abuse 계층을 우회하는 구현은 검증과 사용자 승인 없이 진행하지 않는다. 먼저 필요한 기술 요소, 대안, 유지보수 비용을 보고한다.

## Platform and sources

- Target iOS 27 only. Xcode 27 / iOS 27 SDK를 사용하고 SwiftUI의 현재 네이티브 API를 우선한다. iOS 26 이하 호환 분기와 fallback을 만들지 않는다.
- API의 존재·signature·availability는 로컬 Xcode SDK interface와 compiler를 최종 기준으로 확인한다. 디자인과 권장 사용법은 현재 Apple documentation / HIG를 따른다. 오래된 스킬 예제나 beta 정보가 이 기준을 덮어쓰지 않는다.
- 사용자가 제공한 모든 링크를 직접 열어 내용을 확인한다. 대화 맥락과 함께 판단하고 접근할 수 없는 링크는 명시한다.

## Product and UI

- 시스템 TabView, Search, Navigation, sheet, toolbar, Liquid Glass의 동작이 존재하면 그것을 사용한다. custom imitation으로 재구현하지 않는다.
- Liquid Glass는 장식용 blur가 아니다. 현재 시스템 component와 behavior를 사용하고 navigation, controls, floating player 등 기능 레이어에 적용한다. 콘텐츠 카드 전체를 glass로 만들지 않는다.
- T1(Home/Library + native separated Search), Quick Picks 우선 및 YouTube Music 추천 구조는 유지한다. 그 안의 모든 시각·동작 디테일은 사용자가 제공한 현재 Apple Music reference와 일치시키는 것을 목표로 한다. 관찰하지 못한 동작과 남은 차이를 동일하게 구현했다고 주장하지 않는다.
- 명시되지 않은 기능·탭·화면·버튼·카드·설정을 임의로 추가하지 않는다. 중요한 UX 구조 변경은 구현 전에 이유와 대안을 제시한다. 스킬의 예제 화면이나 탭은 제품 요구사항이 아니다.
- 디자인 판단에는 현재 Apple HIG와 사용자가 제공한 실제 Apple Music reference를 사용한다. 아직 제공되지 않은 reference를 본 것처럼 추정하지 않는다. 일반적인 웹 UI 관습보다 네이티브 iOS 동작을 우선한다.

## Architecture and correctness

- networking / auth / player와 SwiftUI presentation을 분리한다. YouTube Music / InnerTube 구현 세부사항이 View로 퍼지지 않게 한다. 구체적 아키텍처는 실제 요구에 맞추고 과도한 계층을 미리 만들지 않는다.
- Swift concurrency warning과 data race를 무시하지 않는다. isolation, Sendable, cancellation, task lifetime과 UI의 MainActor 경계를 명시적으로 검토한다. 경고를 숨기기 위한 unchecked annotation을 추가하지 않는다.

## Validation

- 의미 있는 UI 변경은 Simulator에서 빌드·실행하고 실제 렌더링 화면과 관련 interaction을 직접 확인한다. 눈에 보이는 문제와 동작 오류를 수정한 뒤 완료한다. 관련 loading·empty·error·recovery 상태도 검증한다.
- 이 작업에 필요한 일반적인 Simulator boot, build 재시도, screenshot 및 interaction 확인은 별도 재확인 없이 수행한다. 실제로 사용할 수 없는 도구나 검증은 완료로 보고하지 않는다.
- XcodeBuildMCP를 우선하되 현재 공개된 tool schema를 확인한다. 스킬에 남아 있는 과거 tool 이름을 그대로 호출하지 않는다. 앱 project/scheme이 생기면 실제 값으로 session defaults를 설정한다.

## Codex routing

- 같은 역할의 범용 전역 스킬보다 아래 프로젝트 스킬을 우선한다. 추가 `liquid-glass` / `liquid-glass-motion` 스킬은 이 프로젝트에서 채택하지 않는다.
- 공식 Build iOS Apps: SwiftUI UI patterns, Liquid Glass, Simulator/debugger, view refactor, performance audit에 사용한다. 범용 스킬의 이전 iOS fallback, 예시 제품 구조, 고정 아키텍처보다 위 프로젝트 조건이 우선한다.
- `.agents/skills/project-design-critique`: 제품 구조와 UX critique.
- `.agents/skills/project-apple-hig`: 현재 Apple HIG와 SDK에 근거한 네이티브 component 선택.
- `.agents/skills/project-interaction-design`: gesture, feedback, 상태·전환·복구·task flow.
- `.agents/skills/project-swift-concurrency`: 비동기 작업의 isolation·cancellation·수명·동시 로딩.
- 프로젝트 shell과 MCP는 `.codex/config.toml`의 `DEVELOPER_DIR`를 사용한다. 전역 Xcode 선택이나 스킬 설치를 바꾸지 않는다. 초기 환경 검증 기록은 `outputs/SETUP.md`에 있다.
