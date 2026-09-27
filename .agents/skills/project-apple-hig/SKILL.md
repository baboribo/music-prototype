---
name: project-apple-hig
description: Verify native iOS component, navigation, gesture, accessibility, and Liquid Glass decisions against current Apple HIG and the installed Xcode SDK. Use for platform-specific UI choices and design reviews.
---

# Current Apple HIG and SDK

For this iOS 27-only project, derive the component choice from the requested task and current Apple guidance, then verify API spelling, availability, and deprecation in the selected SDK. This is a source-finding workflow, not a frozen API catalog.

| Decision | Apple HIG |
| --- | --- |
| Navigation/search | [Navigation and search](https://developer.apple.com/design/human-interface-guidelines/navigation-and-search), [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars), [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields) |
| Temporary tasks/dismissal | [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) |
| Touch/discoverability | [Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures) |
| Transitions/response | [Motion](https://developer.apple.com/design/human-interface-guidelines/motion), [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback) |
| Legibility/input/system preferences | [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) |
| Glass/content layering | [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) |

Open only relevant pages. If a canonical page returns only a JavaScript shell, retrieve its Apple DocC data at `https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<slug>.json`, or use an available browser/documentation tool. Read the content and cite the canonical URL. Report an access failure instead of inferring guidance from its title.

## SDK verification

Inspect the project's effective `DEVELOPER_DIR` and `xcrun --find swift`; resolve SDK paths with `xcrun --sdk iphoneos --show-sdk-path` or `xcrun --sdk iphonesimulator --show-sdk-path`. This repo uses `/Applications/Xcode.app/Contents/Developer` through project configuration. `xcode-select -p` reports the system-wide default and can still point to CommandLineTools; do not change that global setting for this project. Search relevant headers or `.swiftinterface` files; SwiftUI symbols can reside in SwiftUICore. Compiler-check uncertain overload or isolation behavior.

Installed Xcode 27 SDK/compiler interfaces determine what exists and compiles. Current Apple documentation explains intended use. Community skills, beta examples, cached HIG summaries, and generated model-context documents cannot override them. Investigate discrepancies instead of introducing compatibility branches around unverified examples.

Prefer system components and behavior. The live HIG Materials guidance separates Liquid Glass's functional layer from content and recommends sparing custom effects; standard components adopt the system behavior automatically. Re-read the relevant page for material decisions.

Explain the task, native pattern, and material tradeoff proportionately. HIG does not authorize adding a feature. Validate the changed behavior in Simulator as AGENTS.md requires; distinguish simulator evidence from physical-device rendering/performance claims.

Adapted from zanwei/human-interface-guidelines-skill, commit `226cea395234b3552ef494adbb3d406694a3fccd`, reviewed 2026-09-27. Replaces static catalogs/Python dependencies with live official-document routing and SDK verification. [LICENSE](LICENSE) preserves the MIT notice.
