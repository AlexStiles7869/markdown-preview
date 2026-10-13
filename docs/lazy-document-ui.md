# Lazy document-window UI — 2026-10-13

The find-result overlay is constructed on the first nonempty search result and reused for later searches. Empty queries and dismissal do not construct it. Installation precedes applying the first result, preserving its match count and navigation state.

The inspector keeps its split item and saved geometry, but creates its SwiftUI form only when expanded. While collapsed, document delivery and URL changes replace pending input without computing metadata. Expansion applies the latest input before the animation; split-state observation also handles restored or AppKit-driven expansion. Once created, the form is reused, and visible document updates remain immediate.

This reduces work for controls the user has not opened. It does not defer visible toolbar/reader construction, wait for WebKit presentation, or establish a 700 ms launch.

## Profile

Six fresh-process Release launches of the preceding production source were instrumented. The fixture was the 41-byte `fixtures/launch-check/readme.md` in the local handoff directory. Nested spans overlap and must not be added together.

| Operation | Median synchronous time |
|---|---:|
| Document window initializer | 371.62 ms |
| Window setup | 317.23 ms |
| Reader creation/take | 121.91 ms |
| Window presentation request | 97.48 ms |
| Toolbar installation | 79.41 ms |
| Window sizing | 37.46 ms |
| Find overlay installation | 12.96 ms |
| Inspector metadata and display | 0.80 ms |

The hidden find overlay is a small avoidable startup cost. Inspector metadata/display happens after the window request and is cheap on this small fixture; its scans scale with document size. The remaining large costs are not removed by this change.

## Validation

- Release app and embedded Quick Look build pass, with unchanged signing and entitlements. The copied app passes strict deep signature verification.
- 17 focused tests pass: three new inspector lifecycle tests plus editor search, reader lifecycle, and toolbar-order tests. Inspector tests compile the real production controller and SwiftUI view through source symlinks. They cover latest-input selection before first reveal, hidden edits/renames, form reuse, duplicate presentation notifications, presentation before document delivery, and live visible updates.
- Native runtime checks verify first search count, dismissal/reopen, navigation while the inspector is hidden, updated metadata on reopening and visible navigation, read/edit search layout, and first search with no matches in full screen.
- A fresh launch restored the inspector open with correct metadata, exercising the split-state observation in the real app.

## Timing methodology

Normal comparison artifacts contain no profiling hooks. Each gets one predefined registration/cache warmup, followed by six ABBA blocks (12 measured fresh processes per artifact). Filesystem/OS caches are warm, document snapshots are disabled for both through the existing diagnostic default, and all samples are retained. Builds and tests do not run during timing. The Mac is unlocked and kept awake.

The window timestamp follows `makeKeyAndOrderFront`; DOM readiness is the existing replacement-completion callback. Neither measures compositor pixels. These results do not prove Ghostty parity or a maximum launch latency.

An initial 24-run comparison gave 1140.44 → 1151.45 ms window-request medians and 1630.12 → 1655.28 ms DOM medians. A subsequent runtime launch revealed the inspector was saved open after the UI tests. That batch is retained in the evidence archive but is not used to evaluate the collapsed-inspector path. The confirmation runner verifies the saved inspector state is collapsed before every launch and records all split frames.

## Collapsed-inspector confirmation

| Variant | Window-request median (range) | DOM-ready median (range) |
|---|---:|---:|
| Baseline | 1093.68 ms (991.12–1219.17) | 1580.96 ms (1471.43–1675.58) |
| Lazy hidden UI | 1058.94 ms (969.70–1115.91) | 1539.79 ms (1413.56–1610.59) |

There are 12 measured launches per variant, with every pre-launch saved split frame recorded and the inspector verified collapsed. Window-request medians differ by 34.74 ms; DOM medians differ by 41.17 ms. Five of six paired block means improved for window requests and all six improved for DOM readiness. Ranges overlap, and this single machine/session does not establish a universal saving. It supports retaining the small on-demand UI change, not claiming the remaining launch delay is solved. The earlier open-inspector batch remains part of the record: the benefit depends on which UI is actually hidden.

Evidence, scripts, exact executable hashes, per-run samples, profiling patch, and build/test logs are archived locally at `/Users/fauzaan/Desktop/Pluk/issue-492-handoff/lazy-document-ui/`. The baseline production source is `d783337` (same Swift as `fbdf3b0`). Profiling code is excluded from the PR.

## Deeper launch profile

A follow-up diagnostic Release build at `6b8be0e` measured eight fresh processes after one predefined warmup. It uses the same tiny document, snapshots disabled, a visible project navigator, and the inspector verified collapsed. It adds native timestamp markers and a document-start script observing DOM events and the browser's first-contentful-paint entry. These hooks are archived outside the production code. This is a component profile, not a before/after speed comparison.

| Stage | Median | Interpretation |
|---|---:|---|
| Launch request to `applicationWillFinishLaunching` entry | 451.31 ms | Includes process/framework initialization and work before this first marker; not isolated as OS-only time. |
| Will-finish return to did-finish entry | 164.64 ms | AppKit launch interval, not time executing our will-finish callback. |
| Did-finish callback | 34.00 ms | Our synchronous callback and its callees. |
| Document-window initializer | 278.95 ms | Includes the nested construction stages below. |
| Native NSWindow initializer | 43.17 ms | Before split/controller setup. |
| Reader take/create | 74.97 ms | Includes 66.34 ms in `WKWebView` initialization. |
| Toolbar installation | 73.74 ms | Search item factory 22.36 ms; sidebar-mode factory 6.87 ms. AppKit toolbar work outside item factories is 33.96 ms median. |
| Window presentation request | 86.96 ms | Method duration, not compositor presentation. |
| Markdown-to-HTML generation | 12.58 ms | Background worker; dispatch into the worker is 0.07 ms. |
| Render completion to main-actor apply entry | 154.62 ms | Queued continuation during initial UI/run-loop work. |
| `loadHTMLString` call itself | 1.46 ms | Returning from this call does not mean the page has started. |
| Load call return to navigation-start callback | 264.50 ms | Includes WebKit launch/navigation, IPC, and callback delivery; not a pure process-launch measurement. |
| Page DOMContentLoaded | 4.50 ms from page time origin | Browser-side timing, a different clock from native markers. |
| Browser first-contentful-paint | 53.00 ms from page time origin | Range 41–156 ms; not an observed physical screen frame. |

The profiled window-request median was 1076.35 ms and DOM-callback median 1560.51 ms. Same-run window-request-to-DOM interval was 495.10 ms median. Component medians and nested spans must not be added to claim an exact total. Construction times differ from the previous batch; that is not evidence of another optimization.

Three separate sampled launches show main-thread AppKit layout/display-cycle work and project-navigator row creation. `ProjectNavigatorView.outlineView(_:viewFor:item:)` calls `NSWorkspace.icon(forFile:)`, which enters synchronous Launch Services and filesystem metadata lookups. Sampling runs are excluded from the timing summary above.

A second diagnostic build timed these icon calls directly across six fresh processes after one warmup. There were 13 requests per launch, totaling 33.83 ms median. Roughly 30 ms fell inside the render-completion-to-main-actor gap (23.96–40.86 ms across runs), and another roughly 4 ms occurred while navigation was pending. This confirms one contributor, not an explanation for the entire gap.

The largest actionable investigations are to overlap document preparation/navigation with native window construction without gating window display, and to remove synchronous file-specific icon resolution from initial navigator layout. The search toolbar item is a smaller target. No implementation of these hypotheses or expected speedup is claimed by this profile. The 451 ms before the first callback and the 165 ms between launch callbacks also remain only coarsely characterized.

Reproduction scripts, both instrumented binary hashes, raw logs, samples, stack captures, source backups, and the instrumentation patch are in `/Users/fauzaan/Desktop/Pluk/issue-492-handoff/deep-launch-audit/`. The production Swift source was restored after profiling.
