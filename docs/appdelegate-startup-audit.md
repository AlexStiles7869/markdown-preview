# AppDelegate startup audit — 2026-10-13

The remaining AppDelegate launch work was compared with the local Ghostty source at `05dcf887ef51ea27821f20979493306ec3a19149`. Updater deferral and duplicate Settings-read removal were implemented and tested individually and together. Neither produced a reproducible full-app launch improvement, so neither is included in the production patch. The existing PR behavior is preserved. It does not establish a 700 ms launch or change the document/WebKit construction path.

## Ghostty comparison

Ghostty creates its update controller eagerly, then explicitly starts its updater in `applicationDidFinishLaunching`. Its optional quick terminal, undo manager, and menu-shortcut manager are lazy. Menu shortcut synchronization and appearance synchronization are queued on the main thread; appearance has a documented AppKit-lock reason. Font discovery and renderer-device warmup run on worker threads in `src/App.zig`. These are specific choices, not evidence that every startup API is safe to run in the background. Our Sparkle version explicitly requires startup on the main thread.

## Operation-by-operation decision

Eight fresh full-document launches measured synchronous AppDelegate spans. Nested spans are not additive. A second six-run probe separated updater startup and settings subcomponents. All runs are retained; separate smoke runs precede the batches.

| Operation | Observed cost | Decision |
|---|---:|---|
| Updater construction + startup | 14.64 ms median in initial probe; 12.72 ms in split probe | Tested deferring both; removed after the warmed comparison did not improve launch timing. |
| Updater startup alone | 4.53 ms in split probe | Deferring only `startUpdater()` would leave most construction cost early. |
| Settings initialization + immediate refresh | 8.30 ms in split probe; refresh alone 4.55 ms | Tested using initialization on first access and refreshing only an already-created model. Full-app confirmation did not improve; archived. |
| Crash reporter | 13.06 ms | Keep early to retain startup-crash coverage. No background-thread safety claim is made. |
| Appearance and theme migration | Earlier native-only grouped span 3.58 ms; full-app `applyAppearanceMode` alone 0.48 ms | Keep before first window to preserve appearance and migration ordering. These spans cover different work. |
| Menu construction/icons, all install calls | 8.30 ms total per-run median | Keep command availability immediate. Moving static entries into a XIB has no demonstrated launch benefit here. |
| Activation callback | 3.59 ms | Keep external-settings comparison; no large synchronous cost found. |
| Analytics within activation | 0.17 ms | This batch took the existing daily capture guard; it does not characterize the first capture of a new day. Network submission already uses URLSession asynchronously. |
| What's New launch bookkeeping | 0.07 ms | Keep before windows can write prior-use keys; deferral changes semantics. |
| Menu validation | No calls in measured launch path | No launch saving demonstrated by changing validation. |

The initial full-app did-finish callback was 38.12 ms median, including its nested work. Its entire cost cannot explain the gap between an empty native window and the full document window.

## Experimental implementations (not retained)

The experimental `SettingsModel.captureLaunchPreferences()` uses the initializer's values on first access. If restoration or another caller already created the model, it refreshes normally. This preserved the initial preference snapshot used to detect changes made by another app instance while inactive. The Settings-only artifact otherwise preserved Sparkle startup, update observations, menu actions, crash reporting, appearance, and analytics. This patch is archived because the full-app comparison did not show a gain.

The separate updater experiment made the controller lazy, queued startup after the first key window, added a two-second windowless fallback, and forced early startup for manual checks/About. Its runtime checks passed, but its larger lifecycle change did not produce a reproducible end-to-end benefit. The patch remains in the local evidence archive, not this PR.

## Measurements

Warmed confirmation used three uninstrumented Release artifacts: baseline `fbdf3b0`, updater deferral alone, and updater deferral plus duplicate-read removal. Each artifact received a predefined registration/cache warmup before six ABC-CBA blocks (12 measured fresh processes per variant). Every measured run was retained; no builds ran during timing.

| Variant | Window-request median | DOM-ready median |
|---|---:|---:|
| Baseline | 1076.55 ms | 1547.14 ms |
| Updater deferral | 1086.54 ms | 1554.11 ms |
| Updater + Settings change | 1084.05 ms | 1543.07 ms |

The earlier large gain did not reproduce. Five of six block-mean window comparisons were slower for the combined candidate. These data do not support shipping updater deferral as a speed improvement. The duplicate Settings read was then tested alone instead of assuming its synchronous saving improved launch.

A final Settings-only comparison used one predefined warmup for each artifact followed by six ABBA blocks (12 measured launches each):

| Variant | Window-request median | DOM-ready median |
|---|---:|---:|
| Baseline | 1058.49 ms | 1499.04 ms |
| Duplicate-read removal only | 1077.18 ms | 1556.76 ms |

The window ranges overlap (985.74–1173.92 ms baseline, 977.29–1151.89 ms candidate). This is not evidence of a speedup; five of six block-mean DOM comparisons were slower. The Settings-only patch was also removed from production. The two exploratory and confirmation comparison stages plus this final comparison contain 84 measured full-app launches, with no post-hoc removal of slow samples.

The first exploratory updater-only comparison (12 runs per build) gave window-request medians 1196.25 → 1051.49 ms and DOM medians 1684.01 → 1531.03 ms. It had greater baseline variability and did not explicitly warm each artifact immediately before measurement, so it is not used as the final expected speedup.

## Verification and limits

- Experimental normal Release app/embedded Quick Look builds pass; strict deep code-signature verification passes. Signing configuration and entitlements are unchanged.
- 37 focused tests pass: prewarming, toolbar order, theme presets, What's New policy, and analytics helpers. These do not unit-test Sparkle itself.
- In the archived combined experiment, four diagnostic normal launches each initialized Settings once, performed zero duplicate full refreshes, attached one observation set, and constructed/started Sparkle once. Updater work began 131–177 ms after the window-show marker.
- An early-Settings probe initialized once and refreshed once at launch. An early-updater probe started once despite later launch scheduling. All probes matched Settings' automatic checks/downloads and last-check date to Sparkle.
- A diagnostic windowless launch exercised the real fallback: updater started once 2099.67 ms after did-finish returned. No UI/document was created by that probe.
- Native UI testing of the updater-only candidate rendered the fixture and opened General/About. Manual Check for Updates returned the up-to-date result. The Settings-only artifact also rendered `samples/full.md`, including code and math. No candidate remains in the production source.

All timestamps measure method completion or the existing DOM callback, not compositor presentation. Diagnostic hooks and synthetic early/windowless launch flags are archived outside the production patch. First-install/cold-cache launches are not represented by the final warmup-controlled batch. No maximum-latency guarantee is claimed.

Evidence and reproduction scripts: `/Users/fauzaan/Desktop/Pluk/issue-492-handoff/appdelegate-audit/`. Baseline is production commit `fbdf3b0`; instrumented builds are separately identified by executable SHA-256 in their result files. All normal comparison artifacts contain no audit hooks. The production patch does not include either experiment.

## Where the remaining time lies

In the eight-run full-app probe, the non-overlapping updater/launch/activation callback spans total **55.29 ms median**. The interval from activation callback completion to the window-show marker is **399.86 ms median**, range **358.65–564.09 ms**. That interval is not a measurement of one function: it includes the subsequent document-opening/rendering/window path and scheduling. Instrument document creation, window setup, layout, toolbar construction, and reader preparation individually next. Changing AppDelegate call placement alone did not resolve it.

The follow-up [document-window audit](lazy-document-ui.md) profiles the individual components and records the lazy find-overlay and inspector implementation, runtime checks, and full-launch comparison.
