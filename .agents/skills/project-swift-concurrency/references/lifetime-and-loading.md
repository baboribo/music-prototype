# Lifetime and concurrent loading

A view, navigation flow, and playback service may need different lifetimes. Choose the owner before the API; keep transport/auth/player details outside presentation code.

## Structured work and cancellation

Structured child tasks cannot outlive their scope. Cancellation is cooperative, not forced termination.

- Task groups wait for children before returning. Normal scope exit does not mean work was cancelled early.
- After obtaining the only result needed, cancel remaining work where appropriate. The group still waits for children; cancellation-insensitive work can delay exit.
- In throwing groups, choose whether failure should propagate or become a per-item result. Do not assume an unobserved child error immediately makes the group fail fast.
- Check cancellation around expensive work and before committing unwanted results. Propagate cancellation distinctly from user-facing failure.
- A stored unstructured Task is not a structured child; its owner must cancel or finish it deliberately.
- Task.sleep suspends and cooperates with cancellation; it does not need an actor hop merely to avoid blocking. Task.yield is not a reliable test synchronization primitive.

## Search, refresh, and stale results

Cancellation may not stop an older response from arriving. Define the request that owns visible state; use request identity/generation where necessary before committing results, including after actor reentrancy.

Preserve query/context and useful content during retries where the agreed UX calls for it. Do not let a superseded error replace current success. Distinguish auth, transport, unavailable content, and cancellation at the service boundary.

Do not add debouncing, optimistic updates, retries, or caches solely because a guide mentions them. When required, define timing, ownership, rollback, cancellation, and invalidation.

## Concurrent network loading

Parallelize requests only when independent. Bound large fan-outs according to resource/service limits; no universal concurrency count is assumed.

Aggregate child results in a safe owner, not through concurrent mutation of a captured array or presentation model. Preserve stable identity/ordering for out-of-order completion.

For shared authentication refresh or fetches, decide whether callers join one operation and whether one consumer's cancellation cancels shared work. A disappearing view should not incidentally terminate work another owner still needs.

Prefer suitable URLSession async APIs. Nonblocking I/O does not justify Task.detached. Move expensive decoding/transformation off MainActor through compiler-verified boundaries.

## AsyncSequence and callback bridges

Use AsyncSequence for events over time; a single response normally needs an async function.

- Define producer, iterator, and underlying subscription/delegate ownership.
- Finish on completion/terminal failure; clean up upstream work on termination within its isolation rules.
- Choose buffering intentionally. Unbounded streams can retain obsolete events; dropping values is not valid for every event type.
- AsyncStream does not automatically provide upstream backpressure or broadcast semantics for multiple consumers.
- Inspect long-lived observation loops and retain cycles. Weak capture can still retain an owner indefinitely if promoted strongly for the whole loop.
- Resume continuations exactly once and define the completion/cancellation race. Prefer existing async APIs where available.

## Verification

Select tests for the changed invariant: replaced queries, out-of-order responses, shared-work cancellation, partial failure, view dismissal, stream termination, or deallocation. Use controllable fakes/explicit synchronization where needed, not arbitrary sleeps as proof of race freedom.

Build under actual language/isolation settings, including warning checks. Compiler success cannot prove correct task ownership, cancellation behavior, or stale-result rejection.
