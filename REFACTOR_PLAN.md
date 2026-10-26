# Inputscape v2 — Refactor plan

> Status: agreed 2026-10-26, refined the same day. **v2 rewrite landed 2026-10-26** (phases 1–5 in one pass, at the user's request): new modules, SQLite store, Today / History / Live / Settings / menu bar, legacy import. v1 code removed. Open: Phase 0 probes P1–P8 still to run on the real machine; phase 6 cleanup of old docs. Supersedes `PROGRESS.md` and `INPUTSCAPE_DESIGN_PLAN.md`.
>
> Dev notes: build with `scripts/build-app.sh`; tests with `scripts/swift-test.sh`; offscreen page snapshots with `build/Inputscape.app/Contents/MacOS/Inputscape --snapshot <dir> [yyyy-MM-dd]`.

## 1. Goal

A personal tool for one question: **how do I actually use my Mac in a day of working with AI?** The window is an end-of-day review; the menu bar is a glance.

| Question (ranked) | Answered by |
|---|---|
| 1. Rhythm & fatigue | Active time, day timeline with breaks, longest stretch, focus blocks, late night |
| 2. Where my hands go | Keyboard heatmap, trackpad surface (landings / contact time), top keys & shortcuts, gesture mix |
| 3. Change over time | Calendar, week-over-week, hour × weekday, input-language share |

## 2. Decisions

| Topic | Decision |
|---|---|
| Audience | Personal use only, not a product |
| Privacy | Record the active **input source category** per minute. Never typed characters, key sequences, IME composition, window titles, URLs, screen coordinates or raw event streams |
| Frontmost app | **Not recorded** (dropped in the second session): no app column, no categories, no app filter |
| Devices | Built-in MacBook keyboard (US ANSI) and built-in trackpad only. No device attribution, no other keyboard templates |
| Keep | `KeyboardLayoutSpec`, `KeyboardHeatmapView` geometry and keycap rendering, dynamic `Theme` mechanism, live touch-ellipse panel |
| Visual direction | **Native Mac, refined**: system fonts and semantic colors, automatic light/dark. Heat keeps v1's purple (keyboard) and coral (trackpad), 5 log-scale steps |
| Rhythm | Break = 5 min without input. Logical day 04:00 → 04:00. No live nudges, review only |
| Legacy data | Import the 20 v1 days (2026-09-22 → 10-13) as daily totals, flagged legacy |
| Method | **Verify before trusting**: every signal must pass a labeled test (Phase 0) before it reaches the UI |

## 3. Why v1 went wrong

- Metrics chosen by ease of capture, not meaning ("trackpad operations" summed clicks + scroll sessions + swipes; touch grid counted 125 Hz frames).
- Signals built on unverified assumptions: system gesture events rarely reach the tap; the pressure-stage event (type 34) never reaches it; "pressure" was actually `zTotal` capacitance. Pressure was rewritten ~5 times.
- Effort spent on peripherals (791-line custom date picker).
- Storage kept daily totals only, so new questions can't be answered from old data.

What the 20 stored days show: top keys are always Space, Delete, I, N, A (Pinyin typing, plus autorepeat inflating Delete); early days log 0.2–0.9 h active time against 6–10K keys; 10-14 → 10-25 is missing with nothing marking it as "not recording".

### Confirmed capture defects (fixed by the rewrite)

1. Key autorepeat counted as presses (`EventMonitor.swift` keyDown).
2. ⇧ + letter/digit counted as a shortcut; 150 ms wall-clock combo debounce.
3. MTTouch offset 52 is `float pressure` but stats use `zTotal`.
4. Touch heatmap counts frames, not touches.
5. Active time ignores touch; lost on restart (`loadToday` doesn't seed closed sessions).
6. Only vertical scroll axis; scroll counted as sessions, not distance; continuous flag unread.
7. Touch listener not restarted after sleep/wake; no record of when capture was running.
8. "7/30 days" totals use the last N files, not calendar days.
9. Force-click looks for pressure stage 2 *before* mouseDown (backwards) and type 34 never arrives anyway.
10. `event.timestamp / 1e9` assumed nanoseconds (may be mach ticks on Apple Silicon — probe P1).
11. Shortcuts dropped for special-map keys (fn+arrow, ⌃F3…); second same-type modifier missed.
12. Midnight rollover drops up to 5 s; `MTDeviceRelease` over-release; MT frame timestamp ignored.
13. Lab protocols write into real stats.
14. App bundle is hand-made and not reproducible from the repo.

## 4. Architecture

```
Sources/
  KeyboardKit/   ← moved as-is: KeyboardLayoutSpec, KeyCodeMapper
  Capture/       ← EventTap, MultitouchBridge, InputSourceTracker, CaptureSupervisor
  Core/          ← feature events, KeyClassifier, TouchSessionClassifier, InputSourceClassifier, HeatScale, MinuteAccumulator
  Store/         ← GRDB database, migrations, queries, LegacyImporter
  Insights/      ← Rhythm (stretches, breaks, focus, late night), TouchDensity, notes
  App/           ← SwiftUI: Today, History, Live (+ Lab), Settings, MenuBarExtra
Tests/           ← Swift Testing; classifiers tested against recorded fixtures
```

Data flow: **Capture → Core (anonymous feature events, in memory) → MinuteAccumulator (upsert current minute every 15 s) → Store → UI (GRDB `ValueObservation`, no polling)**.

`CaptureSupervisor` owns lifecycle: start/stop on permission, pause, sleep/wake, screen sleep, lock/unlock; restarts the multitouch bridge and event tap after wake; writes a coverage row every minute; routes events to the Lab *or* the store, never both.

### Storage: SQLite via GRDB 7

Fallback if the CLT toolchain can't build it: system `libsqlite3` with a thin wrapper (same schema).

```sql
CREATE TABLE input_source (id INTEGER PRIMARY KEY, tis_id TEXT UNIQUE, kind TEXT); -- zh_pinyin | zh_other | ja | ko | latin | other

-- one row per minute per input source (a minute splits only if the source changed)
CREATE TABLE minute_activity (
  minute      INTEGER NOT NULL,   -- unix time / 60; logical day derived at query time
  src         INTEGER NOT NULL DEFAULT 0,
  active_s    REAL    NOT NULL,
  key_letter INTEGER, key_space INTEGER, key_delete INTEGER, key_return INTEGER,
  key_nav INTEGER, key_digit_punct INTEGER, key_modifier INTEGER, key_function INTEGER,
  key_repeat INTEGER,             -- autorepeat events, not counted as presses
  shortcuts   INTEGER,
  click_press INTEGER, click_tap INTEGER, click_heavy INTEGER, click_right INTEGER,
  click_other INTEGER,            -- mouseDown with no built-in trackpad contact within ±60 ms
  scroll_v_px REAL, scroll_h_px REAL, scroll_momentum_px REAL,
  touch_s     REAL,               -- wall-clock seconds with ≥1 finger down
  touch_move_s REAL,              -- seconds with a moving (non-resting) finger
  pointer_s   REAL,               -- seconds with pointer movement (fallback activity only)
  sess_point INTEGER, sess_scroll INTEGER, sess_pinch INTEGER,
  sess_swipe3 INTEGER, sess_swipe4 INTEGER, sess_rest INTEGER,
  PRIMARY KEY (minute, src)
);
CREATE TABLE key_hourly      (hour INTEGER, src INTEGER, key_id TEXT, presses INTEGER, repeats INTEGER, PRIMARY KEY (hour, src, key_id));
CREATE TABLE shortcut_hourly (hour INTEGER, combo TEXT, count INTEGER, PRIMARY KEY (hour, combo));
CREATE TABLE touch_hourly    (hour INTEGER, cell INTEGER, landings INTEGER, contact_ms INTEGER, PRIMARY KEY (hour, cell)); -- 24×16 grid
CREATE TABLE coverage        (minute INTEGER PRIMARY KEY, state TEXT); -- recording | paused | asleep | locked | no_permission | mt_unavailable | lab
-- legacy (imported once, read-only)
CREATE TABLE legacy_day      (date TEXT PRIMARY KEY, keys INTEGER, clicks INTEGER, scroll_legacy INTEGER,
                              scroll_unit TEXT, active_s REAL, flags TEXT);
CREATE TABLE legacy_key      (date TEXT, key_id TEXT, count INTEGER, PRIMARY KEY (date, key_id));
CREATE TABLE legacy_shortcut (date TEXT, combo TEXT, count INTEGER, PRIMARY KEY (date, combo));
CREATE TABLE legacy_touch    (date TEXT, cell INTEGER, contact_s REAL, PRIMARY KEY (date, cell));
```

## 5. Capture spec

| Signal | Source | Rule |
|---|---|---|
| Key press | CGEventTap keyDown / flagsChanged / systemDefined | Skip if `keyboardEventAutorepeat` ≠ 0 (count into `key_repeat`). Classify into letter/space/delete/return/nav/digit-punct/modifier/function. Left/right modifiers from device-specific flag bits; Caps Lock counts once |
| Shortcut | keyDown with modifiers | Only if ⌘ or ⌃ held. Includes special-map keys. No debounce |
| Input source | `TISCopyCurrentKeyboardInputSource` on main thread at start, on `kTISNotifySelectedKeyboardInputSourceChanged`, wake, app activation; cached atomically for the tap | Classify: keyboard layout → `latin`; `zh` + pinyin/ITABC/Shuangpin/wetype/sogou → `zh_pinyin`; other `zh` → `zh_other`; `ja`, `ko`; else `other`. Raw id kept. Known limit: Shift-to-English inside Pinyin is invisible |
| Touch session | MultitouchSupport frames (built-in device only) | Session = first contact → all fingers up (+80 ms grace). Features: max fingers, duration, centroid travel, spread change, click during session. Classified as tap / point / scroll / pinch / swipe3 / swipe4 / rest |
| Landing / contact | same frames | Landing = finger id's first frame. Δt from the MT frame timestamp, capped at 50 ms. Resting vs moving split by centroid speed (P4) |
| Click | leftMouseDown / rightMouseDown | Trackpad only if MT contact within ±60 ms, else `click_other`. Tap vs physical: MT pressure peak > ~110 (verified). Heavy: pressure peak during/after mouseDown within ~300 ms above threshold from P5 |
| Scroll | scrollWheel | Continuous only. Pixel deltas on both axes; momentum phase separate |
| Time | callback | Minute assigned by wall clock; durations from `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`. Never `event.timestamp / 1e9` |
| Activity | key press, modifier down, mouseDown, scroll, moving touch; pointer move only while MT is down | Segment ends after a 60 s gap; `active_s` = segment overlap with the minute |

Not captured: frontmost app, system gesture events, pressure-stage events.

## 6. Metrics

Pure functions in `Insights/Rhythm.swift` over minute rows.

| Metric | Definition |
|---|---|
| Logical day | 04:00 → 04:00 local |
| Active minute | `active_s ≥ 10` |
| Pause | 1–4 inactive minutes, inside a stretch |
| Break | ≥ 5 inactive minutes, or locked/asleep |
| Unknown | paused / no permission / no coverage — hatched, never a break, marks the stretch incomplete |
| Stretch | first → last active minute with no break inside; longest shown with start/end |
| Long stretch | > 60 min |
| Focus block | stretch ≥ 25 min with ≥ 60 % active minutes |
| Late night | active minutes 23:00–04:00 + last active time |
| Keys / clicks / scroll | each in its own unit, never summed |

## 7. UI spec

Sidebar: **Today / History / Live / Settings** (Lab only when Settings › Advanced › Show Lab). Try `NavigationSplitView`; fall back to the v1 HStack shell if the toolbar-inset bug returns. App follows system light/dark (`AppearanceManager` removed). Theme gains spacing/radius/typography tokens; numbers `.monospacedDigit()`. `HeatScale` (log, 5 steps, 1-2-5 legend) replaces `HeatLegend`; `HeatRamp` derives fill and text color from the same level.

| View | Contents |
|---|---|
| **Today** (default; any day or range) | Numbers strip (active time, longest stretch, keys, clicks, scroll distance). Full-width Swift Charts timeline: keys/min above, moving-touch seconds below, separate scales, 5-min bars; gray breaks, hatched unknown, late-night tint, longest-stretch bracket; hover details; ranges show the average-day profile. Keyboard panel: heatmap with hover tooltip (count, share, top shortcut), top keys/shortcuts list, `All / 中文 / English` filter, Pinyin labels (Space = commit candidate, 1–9 = candidate pick, Delete = edits), hide Space/Delete. Trackpad panel: Gaussian surface (24×16 → ×8, σ ≈ 1.3 cells, log-normalized, `CGImage` off main thread), landings / contact time toggle, hover region + share. 2–3 notes from verified signals only |
| **History** | Calendar heatmap by active time (click a day / shift-click or drag a range → Today); legacy days hatched. Week-over-week (to date vs same weekdays). Hour × weekday grid. Chinese-input share over time |
| **Live** | Keyboard with pressed keys + live touch ellipses (kept, 30 Hz inbox is the only timer). Lab behind the toggle |
| **Settings** | Permissions, pause, Show Lab, data (delete day / all, export DB) |
| **Menu bar** | Active time, current stretch, longest stretch, 24-h mini strip, pause, Open |

`KeyboardHeatmapView` changes are additive only: a `heat:` parameter (default = current behavior) and `keyRect(_:unit:)` + `.onContinuousHover` hit-testing for the tooltip; aspect ratio derived from `KeyboardLayoutSpec`.

Removed from v1: `CustomRangePicker`, pressure histogram card, calibration module and `PressureStage*`, "operations composition" card, repeated stat cards, `KeyboardTemplate` + onboarding keyboard step, 3-second refresh timers, `.id` page rebuilds, env-var debug hooks, linear `HeatLegend`, `AppearanceManager`.

## 8. Legacy import rules

| v1 field | Treatment |
|---|---|
| `keyCounts`, `activeSeconds` | Import as is. Flag `repeat_inflated`. Flag days before the active-time fix `active_time_broken` |
| `comboCounts` | Drop combos that are ⇧ + letter/digit with no ⌘/⌃/⌥ |
| `touchGrid` | `contact_s = count / 125` (approximate finger-seconds); 96×64 days downsampled first. No landings |
| `trackpadCounts` click + forceTouch | Summed into `clicks` |
| scrollUp/Down/Horizontal/Session | `scroll_legacy` with `scroll_unit` = `events` (before 09-25) or `sessions` (from 09-25); never mixed with pixel distance |
| `touchPressureHistogram`, swipe, smartZoom, zoom, `hourlyByOp`, `buckets` | Dropped (buckets optional as a legacy timeline if cheap) |

Runs once at first launch of v2; original JSON moved to `~/Library/Application Support/Inputscape/legacy-json/`.

## 9. Build and tooling

- `Packaging/Info.plist` + `scripts/build-app.sh` build `build/Inputscape.app` from scratch and sign with `$INPUTSCAPE_SIGN_ID` (default: the current Apple Development identity), keeping bundle id `com.bintao.Inputscape` so TCC permissions survive. Replaces the old `build-release.sh` (removed).
- GRDB 7 via SwiftPM under Command Line Tools; commit `Package.resolved`; first fetch needs `--disable-sandbox`.
- New tests use Swift Testing; `run-tests.sh` stays for the old XCTest files until migrated.

## 10. Phases

| Phase | Work | Usable result |
|---|---|---|
| **0 · Verify + tooling** (1–2 d) | Commit Lab. `build-app.sh` + plist. Probes P0–P8; fixtures saved | v1 + Lab, reproducible build, probe table below |
| **1 · Capture + store** (3 d) | KeyboardKit / Capture / Core / Store, input source, coverage; runs beside v1 writing SQLite | v1 + Settings line with today's v2 active time |
| **2 · Today vertical slice** (3–4 d) | New shell, Today on the new store, `Rhythm`, notes | New Today page is the default; v1 pages under "Old views" |
| **3 · Menu bar + Settings** (1 d) | MenuBarExtra glance, Settings | Daily glance |
| **4 · Legacy import** (0.5 d) | `LegacyImporter` | Old 20 days open in Today, flagged |
| **5 · History** (3 d) | Calendar, week-over-week, hour × weekday, language share | Full review loop |
| **6 · Cleanup** (1–2 d) | Delete v1 views and dead code, one-page doc replaces `PROGRESS.md`, remove `.build` cache | Clean app |

Exit checks: Phase 0 — each probe ≥ 95 % correct or the signal is dropped / marked approximate. Phase 1 — a full day with coverage ≥ awake time; sleep/wake shows `asleep` and MT resumes. Phase 2 — on real data in light and dark: tooltip = list counts, a deliberate 6-min break shows on the timeline, switching input source moves counts between 中文 and English. Every phase — relaunch keeps the day's active time.

### Phase 0 probes

| Probe | What | How | Status |
|---|---|---|---|
| P0 | `swift test` with Swift Testing under CLT | run it | **pass** (2026-10-26) with explicit `-F`/rpath to CLT `Library/Developer/Frameworks` → `scripts/swift-test.sh`. CLT has no XCTest, so the old suite stays on `run-tests.sh` until migrated |
| P1 | CGEvent timestamp units | Lab "事件时间戳单位" card: Δtimestamp vs Δuptime over live events | readout built, not yet run |
| P2 | Autorepeat flag | Lab key-repeat protocol (hold Delete ×5) | — |
| P3 | Left/right modifiers | press each modifier alone and with its twin held | — |
| P4 | Resting vs moving finger | rest / point protocol | — |
| P5 | Heavy click threshold | Lab pressure protocol (force step now asks for 10 presses) | partial: tap vs click ~110 verified; force ~300 from 1 sample |
| P6 | Scroll phase fields | scroll + fling protocol | — |
| P7 | Sleep/wake | sleep the Mac, check MT resumes | — |
| P8 | Input source ids | Lab "输入源" card while switching ABC / Pinyin, Shift-to-English, Caps Lock; compares notifications vs 1 Hz polling; "保存" writes the ids as a fixture | readout built, not yet run |

## 11. Risks

- **Private framework** (MultitouchSupport) can break on a macOS update → trackpad data goes empty, everything else works; coverage shows `mt_unavailable`.
- **Touch-session thresholds** need tuning; fixtures keep them honest.
- **GRDB build** under CommandLineTools — fallback is system SQLite.
- **Input source** can't see Shift-to-English inside Pinyin; labelled "Chinese input method on".
