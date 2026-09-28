# NER Logistics: Apple HIG Design Audit, V2 (re-audit and implementation plan)

**Apps audited:** `ner_logistics` (Flutter, field officer and rider app) and `NER-Website` (React, control room, district and field dashboards)
**Date:** 2026-09-27
**Follows:** `UI_AUDIT_APPLE_HIG.md` (V1, same day). V1 findings keep their IDs (F-xx, W-xx, plus N-x and NW-x from the pipeline analysis). New findings in this audit are **F2-xx** (Flutter) and **W2-xx** (web).
**Benchmark:** Apple Human Interface Guidelines, via the `apple-design-skill` local mirror. React changes were also reviewed against the `vercel:react-best-practices` checklist.
**Type of audit:** static review of the full before/after diffs, grep metrics, computed contrast ratios, the project's own analyzer, test, type-check and build runs, and one headless render of the public web page.

---

## 1. Scope, method and limits

**Scope**

| App | Path | Diffed against | Excluded |
|---|---|---|---|
| Flutter | `ner_logistics/lib` and `ner_logistics/test` (33 lib files and 2 test files changed) | the pre-change snapshot `scratchpad/baseline/flutter` | `build/`, platform folders, `*.g.dart` |
| Web | `web/NER-Website/src` (32 files changed, 3 new) | the pre-change snapshot `scratchpad/baseline/web/src` | `web/src` (stale), `src/auth-dedicated/`, `src/imports/` |

**Method**

1. Read every hunk of `diff -ruN baseline → current` for both apps, not only the change logs (`02_flutter_changes.md`, `03_web_changes.md`).
2. Graded each V1 finding and each pipeline finding as **Fixed**, **Partial**, **Not fixed** or **Regressed**, with `file:line` evidence from the current code.
3. Looked for problems the implementers introduced: broken behaviour, focus and dialog bugs, Leaflet sizing inside `<dialog>`, line-ending damage, feedback copy that claims something happened when it didn't, and any re-added demo data.
4. Re-ran the checks myself (Section 2.3). The web build went to a scratch `outDir`, so the project's `dist/` is untouched.
5. Computed WCAG contrast for every new colour token and for the new focus ring (Appendix B).

**What this audit did not do**

- It did not run the Flutter app on a device or simulator. It did not sign in to the web dashboard, because that needs a real Supabase account and this audit must not create users or touch the hosted project. Every dashboard finding is therefore "confirmed in code".
- It did not test with VoiceOver, TalkBack, Full Keyboard Access, Increase Contrast or a real Reduce Motion setting. The Flutter widget tests do exercise semantics guidelines, 200% text and `disableAnimations`.
- The headless Chrome render at 1280 px showed the public splash page correctly. The 390 px render was cropped by the headless window's minimum width, so it proves nothing about mobile layout either way.

---

## 2. Executive summary

The two implementation passes made real, measurable progress. The Flutter app went from almost no screen-reader support to labelled controls throughout. It now honours text size up to 200%, uses real platform switches and alerts, and no longer shows emoji or a fake status bar. The web app now has one accessible modal primitive, AA-passing text colours, 44 px touch targets, toasts with Undo, and empty states that offer a next step. Both apps build, analyze and test at or better than baseline, and **no demo data was re-added**.

The biggest remaining problems are about **truthfulness**, not visuals. Both apps still show success messages for things that never left the device, and a few of the new messages make it worse. The worst case: a field officer's incident report says "Notified: District officer + control room" and "Synced", but it is only held in memory. That also silently disables the new sign-out safety check for field officers (F2-01). On the web, the new toasts say "escalated to Control Officer" for a change that is saved only in this browser (W2-02). These need copy fixes now and product decisions soon.

### 2.1 Scorecard (before → after)

| HIG area | Flutter app | Web app |
|---|---|---|
| Accessibility: screen reader | 🔴 → 🟠 | 🟠 → 🟢 |
| Accessibility: text size / Dynamic Type | 🔴 → 🟢 | 🟠 → 🟠 |
| Accessibility: contrast (text) | 🟠 → 🟠 | 🔴 → 🟢 |
| Accessibility: keyboard and focus (new row) | n/a | 🔴 → 🟠 |
| Accessibility: target size | 🔴 → 🟢 | 🟠 → 🟢 |
| Accessibility: reduced motion | 🔴 → 🟢 | 🟢 → 🟢 |
| Color and Dark Mode | 🔴 → 🔴 | 🔴 → 🟠 |
| Typography | 🟠 → 🟠 | 🟠 → 🟠 |
| Navigation structure | 🟠 → 🟠 | 🟠 → 🟠 |
| Modality (sheets, dialogs) | 🟠 → 🟢 | 🔴 → 🟢 |
| Feedback and confirmation | 🟠 → 🟠 | 🟠 → 🟢 |
| Loading and empty states | 🟠 → 🟠 | 🟠 → 🟢 |
| Entering data / forms | 🟠 → 🟠 | 🟠 → 🟠 |
| Icons and symbols | 🔴 → 🟢 | 🔴 → 🟠 |
| Search | 🔴 → 🔴 | 🔴 → 🟠 |
| Localization / writing | 🟠 → 🟠 | 🟠 → 🟠 |

Legend: 🟢 meets the guidance, 🟠 partly meets it, 🔴 does not.

Notes on the scorecard:
- **Flutter feedback stays 🟠** because of the false "Notified/Synced" report screen (F2-01) and the remaining simulated successes (F2-02).
- **Web feedback is 🟢 for mechanics.** The copy still has to change (W2-02).
- **Web dark mode 🟠:** the UI is now a consistent light appearance instead of a broken half-dark one. It still does not follow the system appearance.
- **Keyboard and focus** is a new row, because V1 covered it only inside W-07. The focus ring is nearly invisible on the navy sidebar (W2-01).

### 2.2 Grade counts

| App | Findings graded | Fixed | Partial | Not fixed | Regressed |
|---|---|---|---|---|---|
| Flutter (F-01..F-15, N-1..N-6) | 21 | 10 | 10 | 1 | 0 |
| Web (W-01..W-19, NW-1..NW-6) | 25 | 13 | 8 | 4 | 0 |

**New findings:** 10 Flutter (F2-01..F2-10) and 8 web (W2-01..W2-08). None is a regression of a V1 finding. One (F2-09) is line-ending damage introduced by the edit.

### 2.3 Check results (re-run for this audit)

| Check | Baseline | After | Verdict |
|---|---|---|---|
| `flutter analyze --no-pub` | 186 issues, 0 errors, 6 warnings | **162 issues, 0 errors, 5 warnings** | Better. All 5 warnings pre-date the change (unused import in `alerts_screen.dart:5`, `_submitted` in `report_screen.dart:32`, `_viewLabel`/`_secondaryLabel` in `reports_screen.dart:123,134`, `map_legend.dart:82`). |
| `flutter test --no-pub` | 102 passed, 2 skipped | **112 passed, 0 skipped** | Better. There are new HIG guideline tests, and the 200% text smoke walk passes. |
| `npx tsc --noEmit` | 27 errors | **27 errors**, the same set ignoring line numbers | No new type errors. |
| `npx vite build` | success | **success** in about 250 ms, only the existing >500 kB chunk warning | OK |
| Line endings | `taskStore.ts`, `incidentStore.ts` CRLF | **byte-identical to baseline** | OK |
| Line endings | `reports_screen.dart` CRLF (378 lines) | **LF (0 CRLF)** | Damaged, see F2-09 |
| Demo data | `data/demo.ts` and `DEMO_RIDERS` hold empty arrays | unchanged, and no new fixtures in `lib/` or `src/` | OK |

### 2.4 The six issues to fix first

1. **Flutter: a field officer's report claims "Notified" and "Synced" when nothing is sent.** This also makes the new sign-out guard never fire for field officers (F2-01).
2. **Web: toasts claim cross-role actions** ("escalated to Control Officer", "Sent to the District Officer") for changes that only live in this browser's `localStorage` (W2-02).
3. **Web: the keyboard focus ring is 2.3:1 on the navy sidebar,** so keyboard users can't see where they are in the main navigation (W2-01).
4. **Flutter: other simulated successes remain.** These are the alert "Acknowledge" button, the Reports screen's View/Download/Generate and its hard-coded counts, and the hard-coded "09:41" times (F2-02).
5. **Web: a toast and its Undo vanish if the person closes the drawer** that raised it (W2-03).
6. **Flutter: two report-flow controls are still unlabelled or custom.** These are the evidence "Add photo" tile and the trip Compare overlay (F2-04, F2-05).

---

## 3. Verification of every finding

### 3.1 Flutter (`ner_logistics`)

| ID | V1 severity | Grade | Evidence (current code) | What's left |
|---|---|---|---|---|
| F-01 Screen reader | Critical | **Partial** | `Semantics(` went from 3 to 24 and `GestureDetector(` from 25 to 9. Labelled: header (`app_header.dart:82-121` "Menu", "Alerts, N new", "Profile and settings"), report type cards (`report_screen.dart:285-311`), severity (`:577-614`), tabs (`scroll_tabs.dart:49-55`, `alerts_screen.dart:73-80`, `my_tasks_screen.dart:95-102`), drawer rows (`field_drawer.dart:167-172`, `rider_drawer.dart:156-161`), and `SheetHandle` (`trip_widgets.dart:326-331`). Drawers and the profile use `BlockSemantics` and a labelled `ModalBarrier` (`field_drawer.dart:75-88`, `profile_sheet.dart:119-126`). | Evidence tile `report_screen.dart:427`, Compare overlay `route_screen.dart:716-722`, map pins `ner_map.dart:511,604,732` → F2-04, F2-05, A-05 |
| F-02 Text size | Critical | **Fixed** | `MediaQuery.withClampedTextScaling(maxScaleFactor: 2.0)` in `main.dart:67-69`. `eyebrow` is 11 sp (`text_styles.dart:131-133`). There are 0 `fontSize` values below 11 in `lib`. Fixed heights are gone from `ScrollTabs`, the task tabs and `OfflineBanner`. The smoke walk passes at 200% (`test/widgets/empty_data_smoke_test.dart`). | Literal sizes outside the theme remain (typography, A-12) |
| F-03 Targets | High | **Partial** | Header buttons are 48×48 (`app_header.dart:156-166`), and tabs, chips, severity and `_ActionButton` have `minHeight: 44`. The toggle is `Switch.adaptive` (`ner_toggle.dart:13-14`), and `SheetHandle` is 44 high. | Profile camera badge is 22×22 (`profile_sheet.dart:318-330`) → F2-07 |
| F-04 Emoji icons | High | **Fixed** | `IncidentTypeUi` extension (`ner_map.dart:416-435`) is used by the dashboard, report and map. The emoji scan of `lib` finds 0. `_borderColor` CSS strings are gone. | — |
| F-05 Dark mode, tokens | High | **Partial** | Fake Theme picker removed (`profile_sheet.dart`). `Color(0xFFF5F5F1)` → `AppColors.paper`. `withOpacity/withValues` went from 246 to 220. | No `darkTheme` or semantic `ColorScheme` (Later) |
| F-06 Fake status bar | High | **Fixed** | Drawn time, signal and battery rows deleted from the header, splash and login. `statusBarTime` style removed. | — |
| F-07 Navigation | High | **Partial** | `PopScope` in both shells: closes the profile, then the drawer, then returns to the dashboard, then exits (`field_officer_shell.dart:76-94,162-166`, `rider_shell.dart:106-116,137-141`). There is a test for Back. | Hamburger IA kept. The Compare overlay is not closed by Back (F2-05). |
| F-08 Sign-out confirm | High | **Partial** | `confirmSignOut` uses `AlertDialog.adaptive` with a destructive action (`confirm_dialog.dart:26-61`). The rider path counts the real queue (`rider_shell.dart:80-83`). | **The FO path never fires:** every FO report is saved as `synced`, so `pendingReportCount` is always 0 (F2-01) |
| F-09 Reduce Motion | Medium | **Fixed** | The chakra stops under `disableAnimationsOf` (`ashoka_chakra.dart:62-67`), with a test. | Short `AnimatedSize/Container` motion is not gated (F2-10, Low) |
| F-10 Faded text | Medium | **Partial** | Hints, stepper, profile labels, drawer eyebrows and the empty-state icon are now solid (`text_styles.dart:234`, `report_screen.dart:137,150`, `profile_sheet.dart`). `textContrastGuideline` passes on the header, tabs and report step 1. | 3 spots at 2.1–2.8:1 → F2-06 |
| F-11 Feedback | Medium | **Partial** | 9 `HapticFeedback` calls. The ML error now has plain copy plus **Retry** (`ml_widgets.dart:395-400`). Rider SnackBars say "Not sent yet" plus **View queue** (`rider_shell.dart:84-98,232,245`). "Location captured" appears only after a successful fix (`:100-106`). Pull-to-refresh on Route Status and Rider home. | No skeletons. Simulated successes remain (F2-01, F2-02). |
| F-12 Forms | Medium | **Partial** | `autofillHints`, next/done and `AutofillGroup` on login and sign-up. The report wizard confirms "Discard this report?" (`field_officer_shell.dart:48-66`). | Evidence capture simulated. No permission priming (decision / Later). |
| F-13 Localization | Medium | **Not fixed** | 155 `Text('…')` literals, 0 `AppLocalizations`. | Later |
| F-14 Hidden gesture | Low | **Fixed** | `onSubtitleDoubleTap` removed. The portrait lock is kept by project decision. | — |
| F-15 Search, offline toggle | Low | **Partial** | The FO banner uses `isOnlineProvider` (`field_officer_shell.dart:162`), and the dead `_isOffline` is gone. | `ReportScreen._submit` still reads the mock flag (`report_screen.dart:59-61`). The rider still has a manual `toggleOffline` (`rider_shell.dart:202`). No search. |
| N-1 Quick action type | — | **Fixed** | `ReportScreen(key: ValueKey(type), initialType: …)` (`field_officer_shell.dart:252-256`) | — |
| N-2 Back exits app | — | **Fixed** | See F-07 | — |
| N-3 Invisible press state | — | **Fixed** (for `CardSurface`) | The card is painted on the `Material` itself (`card_surface.dart:49-66`), with ink at 0.08/0.06. | The same bug pattern exists in the Alerts tabs (F2-03) |
| N-4 Drawer render bugs | — | **Fixed** | A plain bar child replaces `Positioned`-in-`Row` (`field_drawer.dart:186-197`). A `Material` panel ancestor is in both drawers. The smoke tests are un-skipped. | — |
| N-5 Fake profile controls | — | **Partial** | Theme picker removed, "✓" glyphs dropped | Saves still `Future.delayed` then "Profile updated" (`profile_sheet.dart:100-110`), a decision |
| N-6 Rider actions silent | — | **Fixed** | Truthful SnackBars plus haptic (`rider_shell.dart:84-98`) | SOS wording is a decision |

### 3.2 Web (`NER-Website`)

| ID | V1 severity | Grade | Evidence (current code) | What's left |
|---|---|---|---|---|
| W-01 Contrast | Critical | **Fixed** | `:root` tokens (`index.css:58-66`): `--text-muted #5C6670` = 5.47:1 on cream, `--sidebar-muted #9FB8CC` = 6.38:1 on navy, and the warning, high and pending fgs = 4.66, 5.11 and 5.26:1. `#8A9098` went from 149 to 2 (both non-text). | — |
| W-02 Dark mode | Critical | **Partial** | `resolve()` always returns `'light'` (`lib/theme.tsx:15-18`), and the Appearance section is removed from `ProfilePanel`. No more half-dark UI. | Doesn't follow the system appearance. HIG `dark-mode.md` still expects both. Decision / Later. |
| W-03 Tokens unused | Critical | **Partial** | `var(--` went from 8 to 166. `StatusBadge`, `Shell`, the breadcrumb and `.ner-pop-row` are tokenised. | 1,009 hex values and 956 inline style blocks remain (Later) |
| W-04 Names and glyph icons | High | **Partial** | `aria-*` went from 27 to 84 and `aria-label` from 10 to 30. 5 SVG icons were added (`auth/Icons.tsx`), each with `aria-hidden`. The sidebar toggle has `aria-expanded/controls` (`Shell.tsx:320-323`). Nav has `aria-current`, and the glyphs are hidden. | 20 nav glyphs, the `EmptyState` glyphs and the `📱💻` session emoji (`ProfilePanel.tsx:399-400`) are still Unicode (B-14) |
| W-05 Modal semantics | High | **Fixed** | `components/Modal.tsx` uses native `<dialog>` and `showModal()` in `useLayoutEffect`, with focus restore, Esc and backdrop-click, and a nested-dialog guard. It is used 8 times, and `fixed inset-0` overlays went from 8 to 1 (a decorative `pointer-events-none` transition). Leaflet inside a dialog is safe: `MapViz` initialises in `useEffect` and has a `ResizeObserver → invalidateSize()` (`MapViz.tsx:182-225`). | — |
| W-06 Targets | High | **Fixed** | 30 `pointer-coarse:` uses (44 px on touch, 28 px floor on pointer). Leaflet buttons are 44 px on coarse pointers (`index.css:219`). | — |
| W-07 Focus | High | **Partial** | A global `:where(…):focus-visible` ring (`index.css:143-146`) covers select, textarea, `[role]` and `[tabindex]`. `outline-none` went from 15 to 5 (the rest are legitimate). The `.glass-field` ring is restored (`auth.css:123`). | The ring colour `#2F6F7E` is **2.31:1 on the navy sidebar** and the toast → W2-01 |
| W-08 Navigation | High | **Partial** | `inert={collapsed}` sidebar (`Shell.tsx:188`), labelled nav and breadcrumb, and `aria-current` on the last crumb. Focus moves to `<main>` on page change (`Shell.tsx:125-131`). | No URLs, and no overlay sidebar on small screens. Focus lands on an unnamed `<main>` (W2-04). |
| W-09 Text below 11 px | High | **Fixed** | 0 inline sizes of 8–10 px. `.ner-veh` and `.ner-pop-chip` are 11 px. | Leaflet attribution stays at 10 px (third-party). There is no `rem` scale (Later). |
| W-10 Form labels, tables | Medium | **Partial** | Filter selects labelled. `htmlFor`/`id` on Reports and ReportIncident. Severity is a `role="group"`. `scope="col"` on all 9 tables. | `ProfilePanel` Label/Input pairs are unassociated. "Forgot password?" is `href="#"` (`auth/LoginTab.tsx:69`). |
| W-11 Hover lift | Medium | **Fixed** | The global `main .rounded-xl.border:hover` lift is deleted. `ui-card` is used only on clickable stat tiles, which carry `aria-pressed` (`Incidents.tsx:284-285`, `Tasks.tsx:57-58`). | — |
| W-12 Two design languages | Medium | **Not fixed** | Out of scope for this pass | Later |
| W-13 Feedback | Medium | **Partial** | `lib/notify.tsx` toasts: `role=status`, 5 s, paused on hover and focus, **Undo** on incident and task changes. `window.confirm` in Approvals was replaced by a Modal with Cancel autofocused (`Approvals.tsx`). | `Tasks.tsx:29` still uses `window.prompt`. Copy overclaims (W2-02). A toast is lost on drawer close (W2-03). |
| W-14 Empty and loading | Medium | **Fixed** | `components/EmptyState.tsx` is used in about 11 places, with next actions ("Clear filters", "Show all tasks", "Report Incident", "Refresh"). There are skeletons in Approvals, MlRisk and AIInsights (`LoadingRows`). | — |
| W-15 Search | Medium | **Partial** | `type="search"` on Incidents filters by ID, location and route, and Esc clears it (`Incidents.tsx:326-330`). | Tasks, MyTasks and Approvals have none (B-09) |
| W-16 Document shell | Medium | **Fixed** (reduced scope) | Title trailing space removed. Font stack `'Inter', -apple-system, …` (`index.css:16,70`). `lang` was a V1 false positive (set at build). | `theme-color` / `color-scheme` meta (B-16) |
| W-17 Language coverage | Low | **Not fixed** | New page strings are English literals | Later |
| W-18 Chat placement | Low | **Not fixed** | Chat is still `fixed bottom-5 right-5`, and toasts now also sit at `bottom-5` (W2-06) | B-10 |
| W-19 Dead code, lint | Low | **Not fixed** | — | Later |
| NW-1 Dead FO bell | — | **Fixed** | `onClick → fo-alerts`, label with count, dot only when count > 0 (`Shell.tsx:355-364`) | — |
| NW-2 Collapsed sidebar tabbable | — | **Fixed** | `inert={collapsed}` | — |
| NW-3 System dark → half-dark | — | **Fixed** | Pinned light | — |
| NW-4 Tree-shaken tokens | — | **Fixed** | Tokens are in plain `:root`, and verified in the built CSS | — |
| NW-5 ProfilePanel toggle | — | **Fixed** | `role="switch"`, `aria-checked`, `aria-label`, and a 44×28 (60×44 coarse) hit area (`ProfilePanel.tsx:17-29`) | — |
| NW-6 Severity picker focus | — | **Fixed** | Selection shown with `boxShadow` plus `aria-pressed` (`ReportIncident.tsx:322-327`) | — |

---

## 4. New or regressed findings

Severity uses the V1 scale: **Critical** blocks use, **High** is a real barrier or clear HIG departure, **Medium** degrades quality, **Low** is polish.

### 4.1 Flutter

#### F2-01 · High · Field-officer reports say "Notified" and "Synced", but nothing is sent. This also disables the FO sign-out guard.
- **Evidence:**
  - `report_screen.dart:59-61` sets `syncStatus` from `mockRepositoryProvider.isOffline`, which nothing in `lib` ever sets to true (the only caller of `toggleOffline` is the rider shell).
  - `queueReport` (`mock_repository.dart:155-158`) only appends to in-memory state.
  - The success card shows the hard-coded "INC-2295" and "Notified: District officer + control room" (`report_screen.dart:829-832`).
  - Because every report is `synced`, `pendingReportCount` (`mock_repository.dart:58-60`) is always 0, so `confirmSignOut` in `field_officer_shell.dart:69-72` never asks. Signing out loses the reports.
- **HIG:** `patterns/feedback.md` ("confirm that a significant action or task has completed" only when it has; "Warn people when they initiate a task that can cause data loss"). `foundations/writing.md` ("Be clear").
- **Impact:** an officer reporting a landslide believes the control room knows about it. That is the most dangerous kind of false feedback in a disaster app.
- **Fix (UI-only, A-01):** mark reports `pending` until a real upload exists, and show "Saved on this device. Not sent yet." with the local `RPT-…` id. The sign-out guard then works with no other change.

#### F2-02 · Medium · Other simulated successes and hard-coded "live" values
- Alerts "Acknowledge" is a 1.4 s delay and then "done", with no server call (`alerts_screen.dart:32-36`).
- The Reports screen's View, Download and Generate are fake spinners followed by "Done" (`reports_screen.dart:109-121`). Its counts are hard-coded: "12 total · 3 pending sync", "8 completed · 2 this week" and so on (`:60-88`). These are demo-style numbers, which conflicts with the no-demo-data rule.
- Hard-coded times and IDs: "updated 09:41" (`alerts_screen.dart:181`), "Timestamp: 09:41:33 · GPS …" (`report_screen.dart:505`), "09:41 today" (`logistics_screen.dart:294`), "Good morning" at any hour (`rider_dashboard.dart:165`), fixed report location and GPS (`report_screen.dart:55-56`).
- **HIG:** `patterns/feedback.md`, `foundations/writing.md`. **Fix:** A-02 and A-11. Some items are product decisions (Section 7).

#### F2-03 · Medium · Alerts tabs have an invisible press state (the N-3 bug again)
- `InkWell` (`alerts_screen.dart:83-89`) sits under `Container(color: Colors.white)` (`:62-63`), so the ink paints on an ancestor `Material` behind the white box and is never seen.
- **HIG:** `components/menus-and-actions/buttons.md`: "Always include a press state for a custom button." **Fix:** A-03.

#### F2-04 · Medium · Evidence "Add photo" tile is an unlabelled `GestureDetector`
- `report_screen.dart:427-432` has no button role, no label, no press state, and it toggles a simulated capture. It sits inside the report flow that V1 called the app's most important.
- **HIG:** `foundations/accessibility.md` (describe controls for VoiceOver), `buttons.md`. **Fix:** A-04.

#### F2-05 · Medium · Trip "Compare routes" is a custom overlay that Back doesn't close
- `route_screen.dart:709-725` uses a `GestureDetector` scrim with an `onTap: () {}` absorber. It has no `BlockSemantics` and no labelled barrier.
- The shell's `PopScope` doesn't know about it, so Back leaves the trip screen with the overlay's context lost.
- **HIG:** `components/presentation/sheets.md`, `patterns/modality.md` ("Always give people an obvious way to dismiss a modal view"). **Fix:** A-05.

#### F2-06 · Medium · Three faded text styles still fail 4.5:1

| Location | Colour | Ratio |
|---|---|---|
| `alerts_screen.dart:364` "RECOMMENDED ACTION" | slate @ 0.5 | 2.14:1 |
| `route_status_screen.dart:584` | slate @ 0.65 | 2.82:1 |
| `reports_screen.dart:192` footnote | ink @ 0.5 | 2.08:1 |

- **Fix:** A-06.

#### F2-07 · Low · Profile photo badge is a 22×22 target
- `profile_sheet.dart:318-330`. It is labelled now, but too small, and it only toggles local state. **Fix:** A-07.

#### F2-08 · Low · Two custom buttons still have no press feedback
- `_RoleTile` (`login_screen.dart:847`) and the Reports `_ActionButton` (`reports_screen.dart:335`) are `GestureDetector`s with no ink. **Fix:** A-03.

#### F2-09 · Low · Line endings changed in `reports_screen.dart`
- The baseline was CRLF (378 lines). It is now LF, so the diff shows the whole file rewritten and hides the real 10-line change. **Fix:** restore CRLF, or agree to LF project-wide (A-00).

#### F2-10 · Low · Reduce Motion covers only the splash chakra
- `OfflineBanner` `AnimatedSize` (`offline_banner.dart:15`), the evidence `AnimatedContainer` (`report_screen.dart:429`), the profile accordion (`profile_sheet.dart:709-719`) and the trip sheet (`route_screen.dart:677`) always animate. These are short, which the HIG tolerates, but a shared helper makes the rule easy to follow for the new micro-interactions in Part A. **Fix:** A-09.

### 4.2 Web

#### W2-01 · High · Focus ring is nearly invisible on dark surfaces
- The ring `--focus-ring: #2F6F7E` (`index.css:65,145`) measures **2.31:1** against the sidebar navy `#17324D`. WCAG 1.4.11 needs 3:1 for focus indicators.
- It affects every sidebar item, Help, Logout, the toast's Undo and Dismiss (navy toast), and the ProfilePanel header close button.
- **HIG:** `foundations/accessibility.md` ("Let people use the keyboard alone to navigate…"), `foundations/color.md` ("Avoid using only color to indicate focus"). **Fix:** B-01. Gold `#F3D58A` on navy is 9.19:1.

#### W2-02 · High · Toast copy claims cross-role actions that only happen in this browser
- `incidentStore.ts` and `taskStore.ts` read and write only `localStorage` (`incidentStore.ts:14,24`; `taskStore.ts:15,25`). Yet the new toasts say:
  - "Incident escalated to Control Officer." (`Incidents.tsx:256`)
  - "Sent to the District Officer for verification." (`fo/MyTasks.tsx:22`)
  - "Officer assignment saved." for a hard-coded `FO-101` (`Incidents.tsx:254`), while field officers' task lists filter on `FO-1024` (`fo/MyTasks.tsx:74`), so the assignee never sees it.
- **HIG:** `patterns/feedback.md`, `foundations/writing.md`. **Fix:** B-02 now; data wiring is a decision (Section 7).

#### W2-03 · Medium · A toast and its Undo vanish when the drawer that raised it closes
- Each `Modal` mounts its own `<Toaster/>` (`Modal.tsx:41`), and the latest one wins (`notify.tsx:7-14`). Resolve an incident, close the drawer within 5 s, and the toast unmounts with its Undo.
- **HIG:** `patterns/undo-and-redo.md` ("Show the results of an undo or redo"; results must stay reachable). **Fix:** B-03.

#### W2-04 · Medium · Page-change focus lands on an unnamed `<main>`
- `Shell.tsx:125-131` focuses `<main tabIndex={-1}>` (`:415`), which has no accessible name, so screen readers announce nothing useful after navigation. `document.title` never changes per page.
- **HIG:** `components/navigation-and-search/sidebars.md`, `foundations/accessibility.md`. **Fix:** B-04.

#### W2-05 · Medium · Hard-coded values that look live
- "Last updated: 10 sec ago" (`control/CommandCenter.tsx:449`).
- Alternate route "+35 km / +27 min / risk 31" (`Routes.tsx:78-84`).
- Report form defaults of 12 vehicles and "4–6 hours" (`fo/ReportIncident.tsx:333,335`), submitted as data unless the officer edits them.
- A placeholder help-desk number "+91 98765 43210" (`Shell.tsx:446,455`).
- These are pre-existing, but V1 missed them, and they conflict with the no-demo-data rule. **Fix:** B-17; the phone number is a decision.

#### W2-06 · Low · Toast overlaps the chat button on narrow screens
- The toast is `fixed bottom-5 left-1/2` at `z-[60]` (`notify.tsx:34`), and the chat launcher is `fixed bottom-5 right-5` (`ChatPanel.tsx:48`). At phone widths the toast covers the launcher. **Fix:** B-10.

#### W2-07 · Low · Incidents toolbar doesn't wrap
- A fixed `w-52` search plus two selects sit in a non-wrapping `flex gap-2` (`Incidents.tsx:324-340`). On narrow screens this forces horizontal scroll or clipping. **Fix:** B-08.

#### W2-08 · Low · `ProfilePanel` polish gaps
- The Profile/Settings tabs are plain buttons with no `tablist`, `tab` or `aria-selected` (`ProfilePanel.tsx:583-590`).
- The show-password glyph `#9AAAB5` is 2.39:1 on white (`:63-67`).
- Session rows use emoji `📱 💻` (`:399-400`).
- Label/Input pairs are unassociated.
- **Fix:** B-13.

---

## 5. What is now good

**Flutter**
- The shared widgets were fixed once and every caller benefits: `CardSurface` press state on all 46 cards, `ScrollTabs`, `_HeaderButton`, `NerToggle → Switch.adaptive`, `SheetHandle`, `EmptyState`.
- Real HIG tests exist now: `iOSTapTargetGuideline`, `labeledTapTargetGuideline` and `textContrastGuideline` on the header, tabs and report step 1. The whole shell is walked at 200% text for both roles. A regression now fails CI instead of waiting for an audit.
- Platform-correct alerts: `AlertDialog.adaptive` with Cupertino `isDestructiveAction` on iOS, "Cancel" first, and a confirmation only when data could be lost.
- Rider feedback copy is honest ("saved on this device. Not sent yet.") and offers a next step (View queue).
- Back behaves as people expect: it closes the top overlay, then goes home, then exits.
- The offline banner uses real connectivity, grows with text size and is a live region.

**Web**
- One `Modal` built on native `<dialog>`: the browser provides the focus trap, Esc, the top layer and the inert background, in 44 lines. Leaflet inside dialogs measures correctly.
- Semantic colour tokens live in plain `:root` (so they survive Tailwind tree-shaking), each checked at 4.5:1 or better.
- Undo restores exactly the fields a change touched (`Incidents.tsx:245-251`), and the task review reports honestly when a role gate blocks it (`Tasks.tsx:20-27`).
- Destructive confirmation follows HIG `alerts.md`: a specific title ("Reject X's request?"), consequence text, Cancel autofocused, and a red Reject.
- Empty states say what happened and offer the next action. Skeletons replace "Loading…" text.
- Reduced motion also covers the new backdrop and toast animations (`index.css:258-262`).
- No new dependencies. The CRLF store files are untouched, and no demo data was re-added.

---

## 6. Implementation plan

Each item has an ID, a priority, the files, the concrete change, the HIG rationale and an acceptance check.
- **Priority:** **P0** = truthfulness or accessibility blocker, do first. **P1** = interactivity and HIG gaps. **P2** = consistency and polish.
- **Effort:** **S** = under 2 h, **M** = half a day.
- **Rules for both agents:**
  - UI-only: no new backend features and no new dependencies.
  - No demo or sample data. Empty lists stay empty and show `EmptyState`.
  - Truthful copy only: never claim something was sent, notified or synced unless the code did it.
  - Every new animation must respect Reduce Motion.
  - Keep the smoke-test hooks (`Icons.menu`, drawer item text, `Icons.close`).

### Part A: Flutter UI design (for Agent 5)

Run `flutter analyze --no-pub` (must stay at 0 errors and no more than 5 warnings) and `flutter test --no-pub` (must stay all-pass) after the batch.

| ID | Pri | Effort | Files | Change | HIG rationale | Acceptance check |
|---|---|---|---|---|---|---|
| A-00 | P2 | S | `features/field_officer/reports/reports_screen.dart` | Restore CRLF line endings (`perl -pi -e 's/\r?\n/\r\n/'`) so future diffs are reviewable. Do this last, after any edits to that file. | — (housekeeping, F2-09) | `file reports_screen.dart` reports CRLF |
| A-01 | **P0** | S | `report/report_screen.dart:50-70, 824-850` | Create reports with `SyncStatus.pending` unconditionally. On the success card, show the local report `id` (not "INC-2295"). Replace "Notified: District officer + control room" with "Saved on this device. Not sent yet." and use the heading "Report saved" (not "Reported"). Keep the "Sync status: Pending" chip. | `patterns/feedback.md`: confirm completion only when it's true; `foundations/writing.md` | Widget test: submit → `find.text('INC-2295')` finds nothing, "Not sent yet" is present, `pendingReportCount == 1`. A second test: FO sign-out then shows "Sign out with unsent data?". |
| A-02 | **P0** | S | `alerts/alerts_screen.dart:32-36, 181`; `reports/reports_screen.dart:57-121, 192` | Alerts: drop the 1.4 s fake delay in `_acknowledge` and set the state straight to done, labelled "Acknowledged on this device" (the list is the constant `mockAlerts`, so nothing is sent). Drop "updated 09:41" (show nothing, or `TimeOfDay.now()` from when the list was built). Reports screen: remove the hard-coded counts, render View/Download/Generate `onPressed: null` with a caption "Not available yet", and fix the footnote colour. | `feedback.md`; `buttons.md` (don't present actions that do nothing) | `grep -n "09:41\|12 total\|8 completed" lib` → 0 hits; no `Future.delayed` in `alerts_screen.dart`/`reports_screen.dart` |
| A-03 | P1 | S | `alerts_screen.dart:62-100`; `login_screen.dart:840-925` (`_RoleTile`); `reports_screen.dart:330-360` (`_ActionButton`) | Give every custom tappable a visible pressed state. In Alerts tabs, move the white fill onto a `Material(color: Colors.white)` wrapper (or wrap each tab in `Material` + `Ink`) so ink shows. Convert `_RoleTile` and `_ActionButton` to `Material` + `InkWell` with `customBorder` matching their radius (same pattern as `card_surface.dart:49-66`). | `components/menus-and-actions/buttons.md`: "Always include a press state for a custom button." | Widget test: `tester.startGesture` on a tab shows an `InkWell` highlight (`find.byType(InkWell)` ancestor present). `grep -c "GestureDetector(" lib` drops from 9 to 7 or fewer. |
| A-04 | P1 | S | `report/report_screen.dart:415-470` | Evidence tile: `Semantics(button: true, label: photoAdded ? 'Photo attached. Remove photo' : 'Add photo')` + `Material`/`InkWell` press state + `HapticFeedback.selectionClick()`. Until real capture exists, subtitle reads "Camera capture isn't connected yet" (no fake "GPS & timestamp auto-attached"). | `accessibility.md` (VoiceOver labels), `writing.md` | `find.bySemanticsLabel('Add photo')` finds one widget; the step 3 screen passes `labeledTapTargetGuideline` |
| A-05 | P1 | M | `trip/route_screen.dart:709-780` (+ callers) | Replace `_CompareModal` with `showModalBottomSheet(context: …, showDragHandle: true, isScrollControlled: true, builder: …)`. This gives drag-to-dismiss, a semantic scrim, and Back closing the sheet, not the screen. Remove the `GestureDetector` pair. | `components/presentation/sheets.md` (a sheet with a grabber supports swipe-to-dismiss), `patterns/modality.md` | Widget test: open Compare → `handlePopRoute()` → sheet gone, trip screen still shown |
| A-06 | P1 | S | `alerts_screen.dart:364`; `route_status_screen.dart:584`; `reports_screen.dart:192`; `tasks/my_tasks_screen.dart:250` (icon) | Replace the `slate500`/`ink` alpha text colours with solid `AppColors.slate500`. | `foundations/accessibility.md`: 4.5:1 for text up to 17 pt | Add the Alerts card (seeded from `test/fixtures` only) to `a11y_guidelines_test.dart` with `textContrastGuideline` |
| A-07 | P1 | S | `profile/profile_sheet.dart:309-332` | Keep the 22 px camera badge visual, but wrap it in `SizedBox.square(dimension: kMinInteractiveDimension)` + `InkWell(customBorder: CircleBorder())`. | `accessibility.md`: 44×44 pt default | Profile header passes `iOSTapTargetGuideline` |
| A-08 | P1 | M | `ml/presentation/ml_widgets.dart`, `route_status/route_status_screen.dart`, `tracking/presentation/live_riders_screen.dart` | Loading placeholders: replace the list-level `CircularProgressIndicator`s on these three screens with 3 placeholder cards the same size as real rows. Use the already-installed `shimmer` package, or a static grey block when `MediaQuery.disableAnimationsOf(context)` is true. Keep small inline spinners on buttons. | `patterns/loading.md`: "Show something as soon as possible … placeholder text, graphics" | While loading, the screen shows 3 placeholder rows; with `disableAnimations: true` no `Shimmer` is built (test) |
| A-09 | P1 | S | new `shared/motion.dart`; `offline_banner.dart`, `report_screen.dart:429`, `profile_sheet.dart:709-719`, `route_screen.dart:677`, both shells | Add `Duration motion(BuildContext c, Duration d) => MediaQuery.disableAnimationsOf(c) ? Duration.zero : d;` and use it in the four animations. Add a 200 ms fade `AnimatedSwitcher` around `_buildBody` in both shells (keyed by the nav value) as the screen-change micro-interaction, also through `motion()`. | `foundations/motion.md`: "Make motion optional"; "Aim for brevity and precision in feedback animations" | Test: with `disableAnimations: true`, switching screens settles in one pump. `grep -c "motion(" lib` ≥ 6. |
| A-10 | P1 | S | `shared/widgets/empty_state.dart`; callers in `my_tasks_screen.dart`, `alerts_screen.dart`, `live_riders_screen.dart` | Add an optional `actionLabel` + `onAction` to `EmptyState` (renders a `TextButton`). Use it for next steps: My Tasks empty → "Report an incident" (navigates to Report), Alerts empty → "Refresh", Live riders empty → "Refresh". | `patterns/loading.md`, `feedback.md` (help people do the next thing) | Empty My Tasks shows a "Report an incident" button that opens the report wizard (test) |
| A-11 | P1 | S | `rider/rider_dashboard.dart:165`; `logistics/logistics_screen.dart:294`; `report/report_screen.dart:490-510` | Greeting by hour ("Good morning/afternoon/evening"). Replace the "09:41 today" and "Timestamp: 09:41:33 · GPS …" literals with the real `DateTime.now()` when the step is shown, or remove the line. No invented GPS: show "Location from device" until location is wired. | `writing.md` ("Be clear"); no fake live data | `grep -rn "09:41" lib` → 0 |
| A-12 | P2 | M | `theme/text_styles.dart`; `reports_screen.dart`; top offenders by `grep -c "fontSize:"` | Add a `footnote` (13 sp) style. Replace inline `TextStyle(fontFamily: …, fontSize: …)` in `reports_screen.dart` and the 3 files with the most literals with `AppTextStyles.*`. Mark page titles as `Semantics(header: true)` (pageHeading usages) so VoiceOver's heading rotor works. | `foundations/typography.md` (consistent hierarchy), `accessibility.md` | `fontSize:` literals outside `theme/` drop by at least 25 (from about 80); `find.bySemanticsLabel` with `isHeader` finds the page title (test) |
| A-13 | P2 | M | `tracking/presentation/live_riders_screen.dart` | Add a `SearchBar`/`TextField` filter above the live riders list (name or vehicle registration, case-insensitive, clear button). This is the one Flutter list backed by real Supabase data, so search has something to search. Show `EmptyState` "No riders match" + "Clear search" when the filter is empty. | `patterns/searching.md` ("search acts as a filter on the current view"), `components/navigation-and-search/search-fields.md` | Test with a fixture list from `test/fixtures`: typing filters the rows, and clear restores them |
| A-14 | P2 | S | `features/field_officer/report/report_screen.dart:_submit`, `field_officer_shell.dart` | Single offline source: after A-01 the report no longer reads `mockRepository.isOffline`. Make `RouteScreen.isOffline` and the banner the only consumers of `isOnlineProvider`. Leave the rider's manual `toggleOffline` alone; it is a product decision (Section 7). | `feedback.md` ("integrate status feedback") | `grep -n "isOffline" lib/features/field_officer` shows only `isOnlineProvider`-derived values |

**Part A total: 15 items** (P0 = 2, P1 = 10, P2 = 3).

### Part B: Website UI design (for Agent 6)

After the batch, `npx tsc --noEmit` must still show exactly the 27 baseline errors and `npx vite build` must succeed. Do not edit `lib/taskStore.ts` or `lib/incidentStore.ts` (they are CRLF). Prefer CSS `:hover`/`:focus-visible` and classes over `onMouseEnter` style mutation (react-best-practices: `js-batch-dom-css`; it also gives keyboard users the same feedback).

| ID | Pri | Effort | Files | Change | HIG rationale | Acceptance check |
|---|---|---|---|---|---|---|
| B-01 | **P0** | S | `index.css:58-66,143-146`; `Shell.tsx` (`<aside>`); `lib/notify.tsx`; `ProfilePanel.tsx` header | Add `--focus-ring-on-dark: #F3D58A` (9.19:1 on navy). Put `data-surface="dark"` on the sidebar `<aside>`, the toast and the ProfilePanel banner. Add a rule `[data-surface="dark"] :focus-visible { outline-color: var(--focus-ring-on-dark); }`. | `foundations/accessibility.md` (keyboard-only use), `color.md` | Tab through the sidebar in Chrome: the ring is visibly gold. The computed ring vs `#17324D` is ≥ 3:1. |
| B-02 | **P0** | S | `pages/Incidents.tsx:252-270`; `pages/fo/MyTasks.tsx:22`; `pages/Tasks.tsx:20-27` | Make toast copy state only what happened locally. Examples: "Incident marked Escalated." (not "escalated to Control Officer"), "Marked complete. Awaiting District Officer review." (not "Sent to…"), "Assigned to FO-101." (name what was set). Keep Undo. | `patterns/feedback.md`, `foundations/writing.md` ("Be clear") | `grep -rn "to Control Officer\|Sent to the District" src/pages` → 0 |
| B-03 | P1 | S | `lib/notify.tsx` | Keep the current toast in module scope (`let current: Toast \| null`). `notify` sets it and calls the top listener. A newly mounted Toaster reads `current` on mount. When a Toaster unmounts, it re-emits `current` to the new top listener. About 6 lines, no API change. | `patterns/undo-and-redo.md` (keep the result and Undo reachable) | Manual: resolve an incident in the drawer, press Esc within 2 s, and the toast with Undo is still visible on the page, and Undo works |
| B-04 | P1 | S | `components/Shell.tsx:125-131, 415`; the page `<h1>`/`PageHeader` (`pages/fo/ui.tsx`) | On page change, focus the first `main h1` (give it `tabIndex={-1}`), falling back to `main`. Set `document.title = \`${t(TITLES[page])} · NER Logistics\``. Give `<main>` `aria-labelledby` pointing to the page heading. | `components/navigation-and-search/sidebars.md`, `accessibility.md` | VoiceOver in Safari announces the page title after a sidebar click. The tab title changes per page. |
| B-05 | P1 | S | `pages/Tasks.tsx:27-31` | Replace `window.prompt` with the `Modal` pattern from `Approvals.tsx`. Use the title "Reject task T-…?", a labelled optional `<textarea>` "Reason", Cancel autofocused, and a red "Reject". The success toast keeps Undo. | `components/presentation/alerts.md`, `patterns/modality.md` | `grep -rn "window\.\(prompt\|confirm\)" src` → 0 |
| B-06 | P1 | S | `pages/Routes.tsx:104,108` and the status `<select>`; `pages/Tasks.tsx:42` | Interim, until product decides (Section 7): render "Apply Rerouting", "Request Inspection" and "+ Create Task" as `disabled` with `aria-describedby` pointing to a visible caption "Not available yet". Either wire the Routes status `<select>` to filter the table (client-side, data already loaded) or remove it. | `buttons.md` (a control must do what it says); `feedback.md` ("Show people when a command can't be carried out") | Every `<button>` in these files has an `onClick` or `disabled` (manual grep) |
| B-07 | P1 | S | `index.css`; `components/Shell.tsx:250-251, 292-295, 322-323, 395-396`; `ProfilePanel.tsx` close button | Add a shared pressed and hover style: `.ui-press { transition: transform .12s, background-color .12s } .ui-press:active { transform: scale(.97) }`, disabled under `prefers-reduced-motion`. Replace the inline `onMouseEnter/onMouseLeave` colour swaps in Shell with CSS classes (`hover:` + `focus-visible:` utilities) so hover and keyboard focus look the same. Apply `.ui-press` to primary and icon buttons. | `buttons.md` (press state), `motion.md` (brief, precise) | `grep -c "onMouseEnter" src/components/Shell.tsx` → 0; with reduced motion on, buttons don't scale |
| B-08 | P1 | S | `pages/Incidents.tsx:318-345`; `pages/Analytics.tsx` and `pages/Reports.tsx` filter rows | Make the filter toolbars wrap: `flex flex-wrap gap-2`, search `w-full sm:w-52`, selects `flex-1 sm:flex-none`. | `foundations/layout.md` (adapt to the available width) | At 390 px width (Chrome DevTools device mode), no horizontal page scroll on Incidents |
| B-09 | P1 | M | `pages/Tasks.tsx`, `pages/fo/MyTasks.tsx`, `pages/Approvals.tsx`, shared bits from `Incidents.tsx:223-240` | Add the same type-to-filter `type="search"` field: Tasks (ID, title, location), MyTasks (ID, title), Approvals (name, email). Use Esc to clear, count it in "Clear filters", and show `EmptyState` "No matches" + "Clear search". Pressing `/` focuses the page's search field when focus isn't in an input (one `keydown` listener in Shell). | `patterns/searching.md` ("Clearly display the current scope", placeholder names what is searched), `search-fields.md` | Typing filters rows on all four pages. `/` focuses search. Esc clears it. |
| B-10 | P1 | S | `lib/notify.tsx:34` | Lift the toast above the chat launcher on narrow screens: `bottom-20 sm:bottom-5`. On `sm+`, keep it centred, which clears the right-hand chat button. | `foundations/layout.md` (don't obscure controls) | At 390 px, a toast and the chat launcher don't overlap |
| B-11 | P1 | S | `pages/Approvals.tsx` (Approve/Reject), `components/MlRisk.tsx` (promote), `pages/Approvals.tsx` Refresh | Busy state on async buttons: `disabled` + `aria-busy` + label change ("Approving…", "Creating alert…") + a small `.ui-spin` glyph (already respects reduced motion). | `components/status/progress-indicators.md`, `feedback.md` | While the RPC is pending, the button reads "Approving…" and can't be double-clicked |
| B-12 | P1 | S | `pages/Incidents.tsx` table rows; `pages/Tasks.tsx` rows | Row interaction feedback: add `focus-within:` background on `<tr>` to match the existing hover (`index.css:256`). After Undo, briefly highlight the restored row (`.ui-flash` background fade 600 ms, off under reduced motion) and scroll it into view. | `undo-and-redo.md` ("Show the results of an undo"), `lists-and-tables.md` | Tabbing to a row's View button highlights the row. Undo scrolls to and flashes the row. |
| B-13 | P2 | S | `components/ProfilePanel.tsx:40-70, 395-402, 580-595` | Tabs: `role="tablist"`, `role="tab"`, `aria-selected`, `aria-controls`, Left/Right arrow keys. `Label` → `<label htmlFor>` with ids on inputs. Password toggle glyph colour `#5C6670` (≥ 3:1). Replace `📱 💻` with two small inline SVGs (or the words "Mobile"/"Desktop"). | `components/layout-and-organization/tab-views.md`, `accessibility.md` | axe (DevTools) shows no "form label" or "aria tab" errors in the panel |
| B-14 | P2 | M | `auth/Icons.tsx`; `components/Shell.tsx:16-40` (NAV icons); `components/EmptyState.tsx` | Finish the icon set with about 15 more inline Feather-style SVGs (stroke 1.5, `currentColor`, `aria-hidden`) for the sidebar nav and the `EmptyState` icons. Change `EmptyState.icon` from `string` to `ReactNode`. No dependency. | `foundations/icons.md`, `sf-symbols.md` (one consistent, weight-matched set) | The Shell NAV array holds no Unicode glyphs; the sidebar looks identical in Safari and Chrome |
| B-15 | P2 | S | `index.css :root`; `components/Shell.tsx`, `pages/fo/ui.tsx` (`PageHeader`, `CardHeader`), `components/EmptyState.tsx`, `components/StatusBadge.tsx` | Add a 5-step type scale in `rem`: `--fs-caption .75rem`, `--fs-footnote .8125rem`, `--fs-body .875rem`, `--fs-title 1.125rem`, `--fs-large 1.5rem`. Apply it to these shared components only. Also add `--space-*` (4/8/12/16/24) for their paddings. | `foundations/typography.md`, `layout.md` | Browser text-size zoom (Chrome "Font size: Very large") scales Shell and headers |
| B-16 | P2 | S | `index.html` | Add `<meta name="color-scheme" content="light">` (matches the pinned light theme, so native controls and scrollbars don't go dark) and `<meta name="theme-color" content="#17324D">`. | `foundations/dark-mode.md` (don't mix appearances), W-16 remainder | Built `dist/index.html` contains both metas; on macOS dark mode, form controls stay light |
| B-17 | P1 | S | `pages/control/CommandCenter.tsx:449`; `pages/Routes.tsx:74-90`; `pages/fo/ReportIncident.tsx:333,335` | Remove "Last updated: 10 sec ago", or compute it from the actual data timestamp. Remove the invented alternate-route numbers block, or show "No alternative computed". Change the `defaultValue={12}` / `"4–6 hours"` to `placeholder`s so no invented values are submitted. | `writing.md`; no demo data | `grep -rn "10 sec ago\|+35 km\|defaultValue={12}" src` → 0 |

**Part B total: 17 items** (P0 = 2, P1 = 11, P2 = 4).

### Suggested order

1. **Agent 5:** A-01 → A-02 → A-03/A-04/A-06/A-07 (one pass over the widgets) → A-05 → A-09 → A-08 → A-10/A-11 → A-12..A-14 → A-00.
2. **Agent 6:** B-01 → B-02 → B-03/B-10 (both in `notify.tsx`) → B-04 → B-05/B-06/B-17 → B-07/B-12 → B-08/B-09 → B-11 → B-13..B-16.

### Later (multi-week or structural; not in this pass)

| Item | Findings | Why later |
|---|---|---|
| Full dark mode: Flutter `ColorScheme` + `darkTheme`; web token migration of about 1,000 hex values, then un-pin `resolve()` in `lib/theme.tsx` | F-05, W-02, W-03 | L effort. 220 Flutter alpha tweaks and about 950 inline style blocks must route through semantic roles first. |
| Bottom tab bar and route-based pages; profile as a real sheet | F-07 | Changes the information architecture; smoke tests walk the drawer |
| URL routing and a responsive overlay sidebar on the web | W-08 | Structural. Cheapest first step: sync `page` to `location.hash` with `pushState`/`popstate` in `App.tsx` (about 15 lines) |
| Localization (ARB / `t()` coverage, hi/as/bn translations) | F-13, W-17 | Needs translated strings |
| App-wide search on FO tasks, alerts and reports | F-15, W-15 | Those lists have no backing data yet |
| Unify the login "liquid glass" with the dashboard; Safari check of `backdrop-filter: url(#…)` | W-12 | Design decision plus a Safari run |
| ESLint + `jsx-a11y`, axe CI; delete `src/auth-dedicated/`; rename `lib/mock_data/` | W-19, D-F10 | Tooling and dev dependencies |
| Location permission priming screen | F-12 | Low value while location is requested after an explicit action |
| Device verification: VoiceOver/TalkBack, max text size, Increase Contrast, Reduce Motion, Safari, real touch-target sizes | all | Needs hardware or simulators and a signed-in test account |

---

## 7. Needs product decision

These can't be fixed by UI work alone. Until each is decided, the plan above keeps the UI **truthful** (disabled, or "saved on this device") rather than hiding or faking it.

| # | Decision | Where | Options |
|---|---|---|---|
| 1 | **Simulated profile saves.** Flutter saves are `Future.delayed(900ms)` then "Profile updated" / "Preferences saved" / "Language applied" (`profile_sheet.dart:100-110`). Notification, 2FA and language toggles aren't persisted. Web notification and 2FA toggles are local state only (`ProfilePanel.tsx`). | Flutter, Web | Wire to Supabase `profiles`, or remove the sections, or label them "Coming soon" and disable Save |
| 2 | **Rider SOS / issue reports aren't sent.** "SOS / emergency" and the four "Report issue" rows all queue the same canned in-memory `RiderIssueReport` (`rider_shell.dart:233-246`). The copy now says "Not sent yet". Nothing syncs the queue. | Flutter | Real emergency channel (call or SMS the desk, Supabase insert + push), or remove SOS until it exists. **Safety-critical.** |
| 3 | **FO incident reports never leave the device**, but until A-01 lands the UI says "Notified" (`report_screen.dart:50-63, 829-832`) | Flutter | Wire `queueReport` to Supabase with a real incident ID, or keep "Saved on this device" |
| 4 | **Dead web buttons:** "Apply Rerouting" and "Request Inspection" (`Routes.tsx:104,108`), "+ Create Task" (`Tasks.tsx:42`), and the Routes status filter | Web | Implement, or remove. B-06 disables them meanwhile. |
| 5 | **The "Accepted" task status** is written by field officers (`fo/MyTasks.tsx:10,19`) but isn't a `TaskStatus` (tsc TS2322 at `MyTasks.tsx:83`). The district view then shows an unknown status. | Web | Add "Accepted" to the task model, or collapse Accept + Start into one step |
| 6 | **`DEMO_RIDERS` in Logistics** (`Logistics.tsx:6,10`): the array is empty, so the page always shows "No riders reporting yet", yet the name implies demo data | Web | Feed `useLiveRiders` from the real live-rider source the Flutter app already uses, or rename and remove the demo module |
| 7 | **Web dashboard locked to light** (`lib/theme.tsx:15-18`). The Dark/System choice was removed in this pass. | Web | Keep light-only (and add B-16 metas), or fund the dark-mode migration (Later) |
| 8 | **Web incident and task stores are `localStorage`-only** (`incidentStore.ts`, `taskStore.ts`). Verify, escalate, assign and review never reach other people or devices. | Web | Move them to Supabase tables with RLS, or relabel the dashboard's collaborative features as local-only |
| 9 | **Hard-coded officer IDs:** Assign always sets `FO-101` (`Incidents.tsx:254`), while "My Tasks" shows only `FO-1024` (`fo/MyTasks.tsx:74`) | Web | Assign from a real officer picker, and filter by the signed-in profile |
| 10 | **Flutter Reports screen** (View/Download/Generate, `reports_screen.dart`) and **Alerts Acknowledge** have no backend | Flutter | Build real exports and acknowledgement, or remove. A-02 disables them meanwhile. |
| 11 | **Evidence capture is simulated** (`image_picker` is unused, `report_screen.dart:427`) | Flutter | Wire `image_picker` + Supabase Storage, or remove the step |
| 12 | **Rider manual "offline" toggle** (`rider_shell.dart:202`), separate from real connectivity | Flutter | Remove it, or keep it as an explicit "offline mode" with that name |
| 13 | **Contact and recovery details:** help-desk phone "+91 98765 43210" (`Shell.tsx:446,455`) and "Forgot password?" `href="#"` (`auth/LoginTab.tsx:69`) | Web | Real desk number, and a Supabase `resetPasswordForEmail` flow or "Contact your administrator" |

---

## 8. Appendix

### A. Metrics (before → after)

| Metric | Flutter | Web |
|---|---|---|
| `Semantics(` / `aria-*` | 3 → **24** | 27 → **84** (`aria-label` 10 → 30, `role=` 8 → 16) |
| Custom `GestureDetector` / raw `fixed inset-0` overlays | 25 → **9** | 8 → **1** (decorative) |
| Text below 11 px/sp | 33 literals ≤ 12 incl. 9–10 → **0 below 11** | 14 → **0** |
| Haptics / toasts | 0 → **9** `HapticFeedback` | 0 → **11** `notify(` |
| Dialogs / confirmations | 0 → **2** (sign-out, discard report) | 1 `window.confirm` → **Modal**; 1 `window.prompt` left |
| Undo | 0 | 0 → **3 flows** (incidents, task review, my-task advance) |
| Pull-to-refresh / skeletons | 1 → **3** / 0 → 0 | n/a / 2 → **5** `ui-skeleton` |
| Empty states with action | 0 | 0 → **5** |
| Search fields | 0 → 0 | 0 → **1** (Incidents) |
| Token use vs hard-coded colour | 246 → 220 alpha tweaks | `var(--` 8 → **166**; hex 1,160 → 1,009 |
| Touch-target rules | `kMinInteractiveDimension` on the header; `minHeight: 44` on tabs and chips | 0 → **30** `pointer-coarse:` |
| Reduce Motion handling | 0 → 1 site (chakra) | yes → yes (+ dialog and toast) |
| Dark mode | none (fake picker removed) | pinned light (half-dark removed) |
| HIG tests | 0 → **5** guideline tests + a 200% text walk | none |

### B. Contrast calculations (WCAG 2.x relative luminance)

| Pair | Ratio | Needs | Pass? |
|---|---|---|---|
| Web `--text-muted #5C6670` on cream `#FAF7F0` | 5.47 | 4.5 | Yes |
| Web `--text-muted` on drawer header `#EEE4D2` | 4.64 | 4.5 | Yes |
| Web `--sidebar-muted #9FB8CC` on `#17324D` | 6.38 | 4.5 | Yes |
| Web `--status-warning-fg #9A6512` on `#FEF8E6` | 4.66 | 4.5 | Yes |
| Web `--status-high-fg #A84C14` on `#FEF1E6` | 5.11 | 4.5 | Yes |
| Web `--status-pending-fg #6E6225` on `#F0EEE6` | 5.26 | 4.5 | Yes |
| Web focus ring `#2F6F7E` on cream `#FAF7F0` | 5.31 | 3 (non-text) | Yes |
| **Web focus ring `#2F6F7E` on sidebar `#17324D`** | **2.31** | 3 (non-text) | **No** (W2-01) |
| Web proposed dark-surface ring `#F3D58A` on `#17324D` | 9.19 | 3 | Yes |
| Web show-password glyph `#9AAAB5` on white | 2.39 | 3 (non-text) | No (W2-08) |
| Web toast error: white on `#7A1B1B` | 10.50 | 4.5 | Yes |
| Flutter `slate500 @ 0.5` on white / paper | 2.14 / 2.08 | 4.5 | No (F2-06) |
| Flutter `slate500 @ 0.65` on white / paper | 2.82 / 2.70 | 4.5 | No (F2-06) |
| Flutter solid `slate500 #5B6472` on paper | 5.47 | 4.5 | Yes |

### C. HIG references used

All under `apple-design-skill/references/`: `foundations/accessibility.md`, `foundations/color.md`, `foundations/dark-mode.md`, `foundations/typography.md`, `foundations/motion.md`, `foundations/writing.md`, `foundations/layout.md`, `foundations/icons.md`, `foundations/sf-symbols.md`, `components/menus-and-actions/buttons.md`, `components/presentation/sheets.md`, `components/presentation/alerts.md`, `components/navigation-and-search/sidebars.md`, `components/navigation-and-search/search-fields.md`, `components/layout-and-organization/lists-and-tables.md`, `components/layout-and-organization/tab-views.md`, `components/status/progress-indicators.md`, `patterns/feedback.md`, `patterns/loading.md`, `patterns/modality.md`, `patterns/undo-and-redo.md`, `patterns/searching.md`, `patterns/playing-haptics.md`.

Quoted rules were checked against the article text in this pass, including `buttons.md` ("Always include a press state for a custom button"), `loading.md` ("Show something as soon as possible"), `feedback.md` (confirmation, warn on data loss) and `undo-and-redo.md` ("Show the results of an undo or redo").

### D. Notes on interpretation

- As in V1, the HIG is a design benchmark here, not a compliance test. Material idioms (ink ripples, `SnackBar`, `Switch.adaptive` on Android) are judged by the outcomes the HIG protects: legibility, target size, screen-reader access, predictable feedback and user control.
- "Truthful feedback" findings (F2-01, F2-02, W2-02, W2-05) are rated as HIG issues because `patterns/feedback.md` and `foundations/writing.md` require feedback that is accurate and clear. In an incident-response app, false confirmation is also a safety risk.
- Counts are from `grep` over `lib/` and `src/` (excluding the out-of-scope folders) and may be off by a few.
