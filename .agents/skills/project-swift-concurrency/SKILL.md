---
name: project-swift-concurrency
description: Design or diagnose async loading, actor isolation, Sendable boundaries, cancellation, AsyncSequence, task ownership, and MainActor state in this SwiftUI client. Use for concurrency code and compiler diagnostics.
---

# Swift concurrency for this project

Read the target's actual Swift language mode, strict-concurrency settings, default actor isolation, and upcoming features before interpreting isolation behavior. Compiler version alone does not establish these settings. If no target exists, identify what remains undecided instead of assuming defaults or creating app code during setup.

For diagnostics, preserve the exact message/symbol, identify the isolation boundary, and make the smallest behavior-preserving correction. Resolve warnings/data races through ownership and type boundaries rather than suppressing checking.

## Ownership and execution

- Isolate UI-owned mutable presentation state to MainActor where appropriate. Keep network/auth/decoding/player responsibilities separate; do not mark the whole app MainActor to silence diagnostics.
- Actors can own shared mutable state. Re-check invariants after suspension because actor methods can be reentrant; not every service/value needs an actor.
- Prefer immutable Sendable values across boundaries.
- `async` does not mean off-main execution. Inspect actual isolation and synchronous work; awaiting network I/O or sleep does not block CPU execution.
- For expensive CPU work, use a compiler-supported isolation mechanism and Sendable boundaries. Verify `@concurrent`, `nonisolated`, and closure syntax against the actual toolchain; do not mechanically rewrite every Task based on its first statement.
- `@unchecked Sendable`, `nonisolated(unsafe)`, and broad `@preconcurrency` need specific safety invariants; they are not routine fixes.

## Lifetime first

| Need | Starting point |
| --- | --- |
| Sequential operation | Direct async call from the existing async context. |
| Fixed independent loads | `async let`, with defined error/cancellation behavior. |
| Dynamic independent loads | Task group, with deliberate fan-out bounds where volume warrants it. |
| View-owned work | SwiftUI `.task` / `.task(id:)` when their lifetime fits. |
| Longer-lived service work | Explicitly owned task with cancellation and cleanup. |
| Event stream | AsyncSequence; AsyncStream only when a callback bridge is needed. |

Read [references/lifetime-and-loading.md](references/lifetime-and-loading.md) for fan-out, stale results, stream cleanup, and verification. Prefer structured work; unstructured tasks need explicit ownership. Task.detached requires a reason to discard inherited context, not simply the presence of networking.

Build with actual target settings and test the affected lifetime/failure path. Use profiling for performance claims. Consult [Swift's Concurrency guide](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/) and current Apple docs with installed interfaces when behavior is uncertain.

Adapted from AvdLee/Swift-Concurrency-Agent-Skill at commit `d5770817d2622e1585b1f7eaebc791a9cb0959c8`, reviewed 2026-09-27. Retains triage/ownership/cancellation/streams; removes blanket task-entry prescriptions, assumed Xcode 26 defaults, and migration-specific process mandates. [LICENSE](LICENSE) preserves the MIT notice.
