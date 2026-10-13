# Defer Settings app discovery — 2026-10-13

`SettingsModel.shared` is initialized during app startup to capture launch preferences. Its initializer also populated the General Settings app picker, enumerating installed editor/LLM apps and loading names/icons before a document window could open.

The initializer now leaves that picker data empty. The existing `GeneralSettingsView.onAppear` refreshes it when the pane is opened, including on later visits. Preference reads, appearance state, updater observation, and saved default selection behavior remain intact. Toolbar discovery follows its own existing path after document DOM completion.

## Measurements

Both experiments used six ABBA blocks (12 fresh app processes per variant), optimized Release builds, warm OS caches, and all samples retained. No builds ran during timing. Native-only variants use the same AppDelegate diagnostic harness with every selected startup operation enabled; the production variants use normal document opening with the same small local Markdown fixture, snapshots disabled, and Files sidebar mode.

| Median | Before | Deferred picker |
|---|---:|---:|
| Settings initialization and refresh, native-only harness | 72.22 ms | 3.27 ms |
| Launch to empty native window request, harness | 607.35 ms | 574.64 ms |
| Launch to document window request, normal app | 1090.34 ms | 1065.32 ms |
| Launch to Markdown DOM completion, normal app | 1523.99 ms | 1533.50 ms |

The synchronous settings work drops by about 69 ms. The normal-app window median is about 25 ms lower, while DOM completion is effectively unchanged. These results do not establish a meaningful end-to-end rendering improvement. First-use costs and scheduling vary: normal-app window ranges were 993–2316 ms before and 967–1225 ms after; DOM ranges were 1413–2877 ms before and 1400–1841 ms after. No outliers were discarded.

Window timing is `makeKeyAndOrderFront` return, not physical presentation. DOM completion is not a compositor fence. This change moves picker preparation to Settings; it does not eliminate that work or remove WebKit startup costs. No Ghostty parity or maximum-latency claim is made.

Normal-app baseline is PR head `6fd5813`; candidate differs by deferring `reloadOpenTargets()` in the settings initializer. Full raw measurements and executable hashes are archived in the maintainer's `issue-492-handoff/settings-defer` folder (`results.json`, `full-app/comparison.json`, per-run samples/logs).

## Validation

- Release app and embedded Quick Look builds pass; copied candidate passes strict deep signature verification.
- All 13 selected prewarming and toolbar-order Swift tests pass.
- Native UI: `samples/full.md` renders; General Settings shows the saved Codex selection; the picker lists installed apps; switching to Reading and back repopulates the picker without changing that selection.
- No signing, entitlement, release-metadata, or menu-XIB changes. The diagnostic AppDelegate harness is not included in the production PR.

A later [AppDelegate startup audit](appdelegate-startup-audit.md) tested further updater and Settings deferrals. They did not improve full-app launch timing and were not retained.
