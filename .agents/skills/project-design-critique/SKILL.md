---
name: project-design-critique
description: Review this native iOS music client's information architecture, visual hierarchy, cognitive load, navigation, discoverability, and UX writing. Use for product or screen critique; use project-interaction-design when specifying behavior.
---

# Native product critique

Review the requested task and actual UI evidence. Identify the user's goal, entry point, frequency of use, and relevant states from the conversation or supplied artifacts. A screenshot cannot prove a gesture, accessibility behavior, or recovery flow.

Use [references/critique-lenses.md](references/critique-lenses.md) for a substantive review. Select relevant lenses; a small fix does not require a complete product audit.

Connect each finding to evidence, task consequence, a named principle, and the smallest useful correction. Prioritize blockers and errors ahead of visual refinements. Label uncertainty and describe how to verify it. Do not invent findings to fill a template.

Judge native components against current Apple HIG and the installed SDK. Web familiarity does not establish that native tab bars, search, sheets, or gestures are wrong. Use actual Apple Music references only when provided or directly inspected; distinguish platform behavior from that app's product choices.

- Review the agreed YouTube Music flow; do not infer features, destinations, cards, filters, settings, or onboarding from a checklist.
- Treat UX laws as diagnostic lenses, not numerical quotas. Do not derive tab counts from Miller's Law, require a three-tap limit, or assume user expertise percentages.
- Prefer system typography, semantic colors, Dynamic Type, and native control states; do not impose CSS pixels, web font scales, an 8px grid, or custom button styling.
- Before a substantial UX structure change, present the current problem, a minimal option, an alternative, and the tradeoff.

Adapted from cuellarfr/design-skills `design-critique`, reviewed at commit `b41750affc03669988b649380756bc17fa427a09` on 2026-09-27. The companion reference retains its heuristic, IA, content, and pattern depth with native calibration. [LICENSE](LICENSE) preserves the MIT notice.
