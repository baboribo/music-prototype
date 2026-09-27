---
name: project-interaction-design
description: Specify and review gestures, feedback, states, transitions, animation, loading, cancellation, and recovery for an agreed native iOS music flow. Use before behavior implementation or when interaction expectations are unclear.
---

# Native interaction design

Specify how the agreed flow behaves. A state inventory makes that interaction reliable; it does not authorize extra screens, controls, or settings.

## Interaction contract

Use the trigger–rules–feedback–lifetime framework where useful:

| Part | Specify |
| --- | --- |
| Trigger | User/system event, discoverable entry point, control/gesture, precondition. |
| Rules | State change, playback/data/navigation effect, duplicate-input policy, success condition. |
| Feedback | Visible/audible/haptic response while pending and on completion; native feedback first. |
| Lifetime | Repetition, leaving the view, interruption, cancellation, retry, background/foreground where relevant. |

Complex flows can use `state + event → next state + effect + recovery`. Model reachable states only. Separate local intent from confirmed remote success.

## States and recovery

Consider relevant states: ready, pressed, selected, unavailable, loading, partial content, empty result, failure, cancelled, completed. Native controls own standard pressed/focus/disabled appearance. Playback may require buffering/interrupted state where the agreed product supports it.

- Preserve useful content and context during refresh/recoverable failure.
- Respond visibly when input is accepted. Show determinate progress only when measured; avoid fake progress and arbitrary delay.
- Match recovery to the cause: retry transient failures, explain unavailable content, or return to an already-defined auth flow. Do not invent recovery actions.
- Define rapid input, stale responses, and cancellation during pending work. Cancellation is not an ordinary failure.
- Prefer proportionate recovery for reversible actions; use confirmation when consequences warrant it.

## Gestures and motion

- Preserve system back, dismissal, scrolling, and control gestures. Custom gestures need a task benefit and appropriate accessible action alternatives.
- Keep direct manipulation coherent with finger movement; verify interruption, reversal, and final state.
- Use native navigation, sheet, toolbar, and Liquid Glass transitions where they express the relationship. Do not impose fixed durations, springs, opacity, or scale across controls.
- Custom motion should communicate causality, location, or state without blocking further input. Check Reduce Motion and retain clear outcomes with less movement.
- Haptics/audio supplement visible state when useful; do not add them everywhere or interfere with music playback.

Exercise the normal path and relevant failure/interruption cases in Simulator, inspect rendering, and fix discovered issues. Verify accessibility actions when custom control semantics change. Record untested device-only behavior.

Keep specifications concise. Do not require story arcs, deliberate friction, celebrations, illustrations, gesture tutorials, or extra buttons unless the agreed design calls for them.

Adapted from cuellarfr/design-skills `interaction-design`, commit `b41750affc03669988b649380756bc17fa427a09`, reviewed 2026-09-27. Retains microinteraction/state/gesture/recovery frameworks; removes web styling, fixed timing/pixel prescriptions, and narrative requirements. [LICENSE](LICENSE) preserves the MIT notice.
