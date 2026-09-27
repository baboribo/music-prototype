# Critique lenses for the native music client

These lenses adapt cuellarfr's heuristic, IA, visual, interaction, and content review framework. Use them to find task failures, not to add UI to satisfy a catalog.

## Evidence and severity

Follow a concrete task from entry to outcome and recovery where interaction is available. Record the device/context. Separate observation from inference and avoid presenting model judgment as user research.

| Severity | Task consequence |
| --- | --- |
| Blocker | Required task cannot complete or causes unrecoverable loss. |
| Major | Frequent or serious confusion, wrong outcomes, or difficult recovery. |
| Minor | Recoverable friction with a clear way forward. |
| Refinement | Presentation inconsistency with little demonstrated task impact. |

Use **evidence → task → principle → correction → verification**. Consider impact, frequency, and persistence instead of merely counting aesthetic differences.

## Information architecture

| System | Questions | Failure signal |
| --- | --- | --- |
| Organization | Do groupings match the listener's tasks? Are overlapping recommendations understandable? | Backend categories dictate UI; content has several ambiguously named destinations. |
| Labeling | Are labels specific, familiar, and distinct? | Different labels mean the same thing, or identical labels produce different outcomes. |
| Navigation | Is location clear? Are back, close, and tab behavior predictable? | Returning loses context; dismissing a temporary task navigates elsewhere. |
| Search | If present in the agreed flow, are scope, query context, and results clear? | No results looks like loading/failure; an older query replaces current results. |

Inspect actual recommendation structure and task frequency before suggesting regrouping. Fewer destinations are not automatically better. Recommendation browsing need not imitate a library hierarchy. Do not add search or filters solely because this lens mentions them.

## Heuristic review

| Lens | Inspect in the requested flow |
| --- | --- |
| H1: System status | Pending actions, buffering, selection, refresh, and completion are distinguishable. Progress is truthful; local intent differs from remote confirmation. |
| H2: User's language | Labels and content order match listener concepts; no InnerTube fields or raw transport errors leak into copy. |
| H3: Control and freedom | Back, dismissal, cancellation, and supported undo reach predictable states and preserve relevant context. |
| H4: Consistency | Native controls behave conventionally; the same action has the same name and effect across the app. |
| H5: Prevention | Accidental or duplicate actions are handled proportionately; safeguards reflect consequence and reversibility. |
| H6: Recognition | Relevant context travels with the task; users need not memorize information from a previous view. |
| H7: Efficiency | Frequent tasks avoid unnecessary navigation; supplementary shortcuts do not hide essential actions. |
| H8: Minimalism | Each element supports content or task; controls, status, and decoration do not compete indiscriminately. |
| H9: Recovery | What failed, what remains available, and a feasible next step are clear; useful state survives retry. |
| H10: Help | Clear controls and contextual explanation come first; separate help needs a demonstrated purpose. |

## Visual hierarchy and cognitive load

- Compare the most prominent element with task priority. A screenshot supports hierarchy analysis, not proof of user behavior.
- Check proximity, alignment, and similarity. Related items read as groups; distinct actions remain distinguishable. Grouping need not add cards or borders.
- Evaluate density against the content and usage context, without fixed limits on list length, colors, or text styles.
- Separate navigation/control layers from content. Liquid Glass should clarify the functional layer rather than compete across every content surface.
- Inspect real artwork, long titles, truncation, Dynamic Type, light/dark appearance, and relevant accessibility settings. Preserve identification of tracks and artists.
- Distinguish selected, playing, loading, and disabled states beyond color alone. Prefer native states.
- Do not impose web assumptions such as dominant filled CTAs, breadcrumbs, hover-only discovery, or desktop reading patterns on every phone screen.

## Task flow and interaction

Trace user intent, the interface's apparent promise, and the resulting behavior. Look for a gap between them.

| Question | Failure to look for |
| --- | --- |
| Discoverable? | An important action exists only through an unmarked custom gesture. |
| Predictable? | Similar controls do unrelated things; an optimistic state silently fails. |
| Proportionate feedback? | Routine changes interrupt; serious errors disappear before recovery. |
| Context preserved? | Returning unnecessarily resets scroll, query, or selection. |
| Resilient? | Repeated input, cancellation, offline changes, or delayed results create contradictory state. |

For reversible actions consider direct recovery when supported; for consequential irreversible actions consider confirmation. Do not mandate either everywhere. Evaluate motion for orientation, continuity, interruption, reversal, and reduced motion. Native navigation/sheet behavior already supplies many of these relationships.

## UX writing

Evaluate copy as usable (clear at the moment of action), useful (serves the task), and responsible (truthful and non-manipulative).

- Name actions consistently and concretely. Distinguish local removal, remote collection mutation, and stopping playback when those actions actually exist.
- Explain the failed outcome, remaining state, and feasible recovery. Include the cause only when known and useful.
- Distinguish empty content, no results, auth failure, unavailable media, transport failure, and cancellation where relevant. This does not require a new screen for each.
- Avoid blame, retry for permanent failures, promises of unavailable recovery, promotional copy, and decorative empty-state additions.
- Keep labels concise and usable with localization, VoiceOver, and large text. Familiar icons still need accessibility labels.

## Review limits

Interaction claims require execution; performance claims require measurement. Report untested behavior. If a reference is unavailable, say so instead of reconstructing its contents from its name or link.
