---
name: project-design-critique
description: Review this native iOS music client's information architecture, visual hierarchy, cognitive load, navigation, discoverability, and UX writing. Use for product or screen critique; use project-interaction-design when specifying behavior.
---

# Adapter (Claude Code → 공유 프로젝트 스킬)

이 파일은 Codex와 공유하는 프로젝트 스킬의 Claude Code용 adapter다. 전체 지침은
[.agents/skills/project-design-critique/SKILL.md](../../../.agents/skills/project-design-critique/SKILL.md)에
있다. 이 스킬이 트리거되면 그 파일, 같은 폴더의 `references/critique-lenses.md`, `LICENSE`를
읽고 그 지침을 그대로 따른다.

내용을 이 파일에 복제하지 않는다. 원본이 갱신되면 이 adapter도 자동으로 최신 내용을 따른다.
이 프로젝트에는 범용 `design:design-critique` 플러그인 스킬(Claude Code 계정에 활성화됨)도
있지만, 그것은 네이티브 iOS/HIG를 모르는 일반 제품 critique용이다. AGENTS.md의 Codex routing
섹션에 따라 같은 역할에서는 이 프로젝트 스킬을 우선한다.
