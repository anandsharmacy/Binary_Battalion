# NER Logistics: Apple HIG Design Audit

**Apps audited:** `ner_logistics` (Flutter, field officer and rider app) and `NER-Website` (React, control room, district and field dashboards)
**Date:** 2026-09-27
**Benchmark:** Apple Human Interface Guidelines, via the `apple-design-skill` local mirror (extracted 2026-07-10)
**Type of audit:** static code review with grep counts and computed contrast ratios

---

## 1. Scope, method and limits

**Scope**

| App | Path | Excluded |
|---|---|---|
| Flutter | `ner_logistics/lib` (105 Dart files) | `build/`, `android/`, `ios/`, generated `*.g.dart` |
| Web | `web/NER-Website/src` (live app) | `web/src` (stale copy), `src/auth-dedicated/` (unused duplicate), `src/imports/` |

**How the HIG applies.** Neither app is a native Apple app, so the HIG is used as a design benchmark, not a compliance test.

- **Flutter app:** judged against **iOS/iPadOS** guidance, since it is phone-first and locked to portrait.
- **Web app:** judged against **macOS and iPadOS-in-Safari** guidance. Pointer targets are judged against macOS sizes, and touch targets against iOS sizes. Where a finding depends on input type, it says so.

**Method**

1. Read the relevant HIG articles under `references/foundations`, `references/components`, `references/patterns` and `references/getting-started`.
2. Searched both codebases for accessibility, typography, color, navigation and feedback patterns.
3. Re-opened the highest-severity findings and confirmed them directly. Counts marked `~` come from a code search and may be off by a few.
4. Computed WCAG contrast ratios for the colors that recur most often.

**What this audit did not do**

- It did not run either app on a device or simulator.
- It did not test with VoiceOver, Dynamic Type, Increase Contrast, Reduce Motion or Voice Control.
- It did not run Accessibility Inspector, axe or Lighthouse.
- It did not measure rendered sizes. Target sizes come from declared widths and heights, not from layout.

Treat every finding as "confirmed in the code", not "observed in use". The Section 6 roadmap ends with a step that turns these into tested results.

---

## 2. Executive summary

Both apps are visually coherent and clearly built with care: the Flutter app has a disciplined navy/paper palette with strong text contrast, and the web app has a real theme system and good chat and ML-notice patterns. The biggest gaps sit under the surface, in **accessibility semantics, text scaling, color/dark-mode plumbing and interaction consistency**. These are the areas the HIG treats as non-negotiable.

### Scorecard

| HIG area | Flutter app | Web app |
|---|---|---|
| Accessibility: screen reader | 🔴 Fail | 🟠 Partial |
| Accessibility: text size / Dynamic Type | 🔴 Fail | 🟠 Partial |
| Accessibility: contrast | 🟠 Partial | 🔴 Fail |
| Accessibility: target size | 🔴 Fail | 🟠 Partial |
| Accessibility: reduced motion | 🔴 Fail | 🟢 Pass |
| Color and Dark Mode | 🔴 Fail (none) | 🔴 Fail (canvas only) |
| Typography | 🟠 Partial | 🟠 Partial |
| Navigation structure | 🟠 Partial | 🟠 Partial |
| Modality (sheets, dialogs) | 🟠 Partial | 🔴 Fail |
| Feedback and confirmation | 🟠 Partial | 🟠 Partial |
| Loading and empty states | 🟠 Partial | 🟠 Partial |
| Entering data / forms | 🟠 Partial | 🟠 Partial |
| Icons and symbols | 🔴 Fail | 🔴 Fail |
| Search | 🔴 Missing | 🔴 Missing |
| Localization / writing | 🟠 Partial | 🟠 Partial |

Legend: 🟢 meets the guidance, 🟠 partly meets it, 🔴 does not.

### Findings by severity

| Severity | Flutter | Web | Total |
|---|---|---|---|
| Critical | 2 | 3 | 5 |
| High | 6 | 6 | 12 |
| Medium | 5 | 7 | 12 |
| Low | 2 | 3 | 5 |
| **Total** | **15** | **19** | **34** |

### The eight issues to fix first

1. **Flutter: screen readers cannot operate most of the app.** Only 3 `Semantics` widgets exist across 105 files (F-01).
2. **Flutter: text does not respond to system text size.** There is no scaling policy, and 33 hard-coded font sizes are 12 or smaller (F-02).
3. **Web: several very common text colors fail WCAG AA.** The grey `#8A9098` used 149 times measures 3.0:1, and sidebar text measures 2.3:1 (W-01).
4. **Web: dark mode only recolors the page background.** Cards and text stay light, so choosing Dark gives a half-dark UI (W-02).
5. **Web: the design tokens are defined but nothing uses them.** 0 uses against about 1,160 hard-coded hex values, which is why W-01 and W-02 are so hard to fix (W-03).
6. **Web: icon-only buttons have no accessible name, and icons are text glyphs.** `Shell.tsx` has no `aria-*` attributes at all (W-04).
7. **Flutter and Web: controls are smaller than the 44 pt touch default.** Examples are a 40×22 toggle and 32 px header buttons (F-03, W-06).
8. **Flutter: emoji are used as functional icons.** They cannot be labeled, styled or scaled like real symbols (F-04).

---

## 3. Flutter app findings (`ner_logistics`)

Severity uses this scale: **Critical** blocks people from using the app, **High** causes real barriers or clear HIG departures, **Medium** degrades quality or consistency, **Low** is polish.

### Critical

#### F-01: Screen-reader support is essentially absent
- **Evidence:**
  - Only **3** `Semantics(` widgets in the entire app (`shared/map/ner_map.dart:496,589`, `ml/presentation/ml_widgets.dart:105`).
  - **0** uses of `semanticLabel`, `ExcludeSemantics` or `MergeSemantics`.
  - **7** tooltips in total.
  - The app header (`shared/widgets/app_header.dart`) builds the hamburger, bell and avatar as unlabeled `GestureDetector`s and `IconButton`s.
  - The incident-type cards in the report flow are unlabeled `GestureDetector`s that show only an emoji (`features/field_officer/report/report_screen.dart:269-292`).
  - `NerToggle` (`shared/widgets/ner_toggle.dart:12-25`) is a `GestureDetector` around an animated box. It has no role, no on/off state and no label.
- **HIG:** `foundations/accessibility.md` ("Describe your app's interface and content for VoiceOver"), `foundations/icons.md` ("Provide alternative text labels for custom interface icons"), `components/selection-and-input/toggles.md`.
- **Impact:** with VoiceOver on, people hear "button" or nothing for the main navigation, the alert bell, the profile avatar, every incident type and every setting toggle. A field officer reporting a flood cannot do so.
- **Fix:** wrap custom controls in `Semantics(button: true, label: …)` or use real `IconButton(tooltip: …)`. Give `NerToggle` `Semantics(toggled: value, label: …)` or replace it with `Switch.adaptive`. Give each report card a label such as "Flood, report incident type".

#### F-02: No text-size (Dynamic Type) policy
- **Evidence:**
  - **0** uses of `textScaler` or `MediaQuery` text scaling.
  - `theme/text_styles.dart` defines a fixed scale from 10 to 26 sp. Its own header says "minimum 14sp anywhere", but it defines eyebrow at 10, `chipLabel` and `caption` at 12, and `disclaimer` at 11.
  - **80** `fontSize:` literals outside the theme, of which **33** are 12 or smaller (for example `report_screen.dart:134` at 9, `alerts_screen.dart:120,295` at 10, `route_status_screen.dart:198,451,468,575,633` at 11).
  - Fixed-height rows such as `scroll_tabs.dart:22` (`height: 38`) will clip when text grows.
- **HIG:** `foundations/typography.md` ("Supporting Dynamic Type", minimum 11 pt on iOS), `foundations/accessibility.md` ("Ideally, give people the option to enlarge text by at least 200 percent").
- **Impact:** Flutter does scale text with the OS setting by default, so text grows, but nothing has been designed or tested for that. Fixed-height chips, the header and dense cards are likely to overflow or truncate at large sizes. Text at 9 to 11 sp is below the HIG minimum before any scaling.
- **Fix:** define a semantic scale (`caption`, `footnote`, `body`, `headline`, `title`) with a floor of 11 sp, and never use a literal size outside it. Clamp scaling deliberately (for example `MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 2.0)`) and replace fixed heights with `minHeight` and padding. Test at the largest accessibility size.

### High

#### F-03: Interactive targets below 44 pt
- **Evidence (declared sizes):** toggle **40×22** (`ner_toggle.dart:16-17`), avatar **36×36** (`app_header.dart:136-137`), header hamburger and bell **40×40** (`app_header.dart:177-178`), scroll-tab chips **38** high (`scroll_tabs.dart:22`), `IconButton`s at ~28 to 36 (`login_screen.dart:~810`, `live_sharing_card.dart:~134`, `live_riders_screen.dart:~222`), and an alert badge 17 high (`app_header.dart:~112`).
- **HIG:** `foundations/accessibility.md`: iOS default control size **44×44 pt**, minimum **28×28 pt**, plus about 12 pt of padding around bezeled controls.
- **Impact:** this app is used by people in the field, often one-handed, sometimes wearing gloves or on a moving vehicle. Small targets cause missed taps on exactly the controls used most.
- **Fix:** use Flutter's `kMinInteractiveDimension` (48) as the floor. Keep the visual size if needed and enlarge the hit area with padding or `SizedBox` wrappers.

#### F-04: Emoji used as functional icons
- **Evidence:** incident types use 🌊 🚧 ⛰️ 🚗 🏗️ 📋 (`field_dashboard.dart:35-39`, `report_screen.dart:230-236`, rendered at 28 px). Other emoji and glyphs appear in `alerts_screen.dart:323` (📍) and in inline "✓" success text. Everywhere else the app uses **259** Material `Icons.*`.
- **HIG:** `foundations/icons.md`, `foundations/sf-symbols.md`. Icons should be a consistent, scalable set that follows text weight and can carry accessibility labels.
- **Impact:** emoji render differently on every OS version, cannot be tinted to match risk colors, do not scale with text, and read out as long Unicode names in a screen reader. They also mix two visual languages in the same screen.
- **Fix:** use one icon set for all incident types (Material Symbols or a bundled set that matches the rest of the app), each with a semantic label. Bonus cleanup: `_borderColor` in `report_screen.dart:230-236` maps strings such as `'border-saffron/50'`, which are leftover CSS class names from the React version.

#### F-05: No dark mode, and color tokens are not semantic
- **Evidence:** only `AppTheme.light` is registered (`main.dart:57-79`), with no `darkTheme` or `themeMode`. `theme/colors.dart` holds static constants. There are **246** `withOpacity` / `withValues` calls and ~20 raw `Colors.*` uses that bypass the tokens (for example `field_officer_shell.dart:123` hard-codes `Color(0xFFF5F5F1)`).
- **HIG:** `foundations/dark-mode.md` ("Ensure that your app looks good in both appearance modes"; "Embrace colors that adapt to the current appearance"), `foundations/color.md`.
- **Impact:** people who use Dark Mode system-wide (common at night, which suits field work) get a bright screen. The scattered alpha tweaks mean a future dark theme cannot be added by swapping a palette.
- **Fix:** move to a `ColorScheme` with semantic roles (surface, onSurface, outline, risk-critical and so on), route all colors through it, then add a dark scheme. Test contrast in both, and in Increase Contrast.

#### F-06: A fake status bar in the header
- **Evidence:** `shared/widgets/app_header.dart:54-63` draws its own time, signal, Wi-Fi and battery row (`_SignalIcon`, `_BatteryIcon`, hard-coded time), while `main.dart:21-27` also makes the real status bar transparent.
- **HIG:** `getting-started/designing-for-ios.md`, `foundations/layout.md` (respect system safe areas and do not imitate system chrome).
- **Impact:** on a real device the user sees two status bars, and the drawn one shows values that are not real (fake battery and signal). Fake system state can mislead a person who is checking connectivity before a trip.
- **Fix:** remove the drawn row, use `SafeArea` for the real inset, and show connectivity through the existing `OfflineBanner`.

#### F-07: Custom navigation instead of standard iOS patterns
- **Evidence:** navigation is a hamburger drawer built from `Stack`/`Positioned.fill` (`field_officer_shell.dart:122-160`, `rider_shell.dart:91-114`), with screens switched by an enum. The profile is a custom overlay, not a sheet (no drag-to-dismiss or detents). Only **4** real routes exist (`app.dart:71-107`), so the swipe-back gesture and deep links do not map to in-app screens.
- **HIG:** `components/navigation-and-search/tab-bars.md` ("Use a tab bar to support navigation"; "Make sure the tab bar is visible"), `components/presentation/sheets.md`, `patterns/modality.md`.
- **Impact:** a hamburger hides the app's 8+ sections behind one tap, so the most-used screens (tasks, alerts, report) are not one tap away. Back-swipe does nothing useful.
- **Fix:** a bottom navigation bar for the 4 to 5 most-used sections (Home, Tasks, Report, Alerts, More), route-based pages under `go_router`, and a real bottom sheet for the profile.

#### F-08: Sign-out has no confirmation, and can lose queued work
- **Evidence:** sign-out calls `signOut()` directly (`app.dart:95,105`). It is reachable from a single row in the drawer and profile sheet. The app queues reports and location for offline sync (`location_queue.dart`, `mock_repository.dart`), and there are **0** dialogs in the whole app.
- **HIG:** `patterns/feedback.md` ("Warn people when they initiate a task that can cause data loss that's unexpected and irreversible"), `components/presentation/alerts.md`.
- **Impact:** a stray tap next to the sign-out row signs the person out mid-shift. If reports are still queued, that data may be lost.
- **Fix:** confirm only when there is unsent data ("N reports haven't synced. Sign out anyway?") using a destructive-style button and a Cancel. Do not confirm otherwise, since the HIG advises against alerts for common, undoable actions.

### Medium

#### F-09: Continuous animation with no Reduce Motion handling
- The splash Ashoka Chakra rotates on an 18 s repeating loop (`onboarding/splash_screen.dart:63-67`). About 108 animation sites exist, and none check `MediaQuery.disableAnimations`. **HIG:** `foundations/accessibility.md` ("Be cautious with fast-moving and blinking animations"), `foundations/motion.md`. **Fix:** stop or slow the spin and replace slides with fades when the setting is on.

#### F-10: Low-contrast secondary text and hints
- `Colors.white54` and `white70` on navy appear 13 times (sign-out in `field_drawer.dart`, header subtitle in `app_header.dart:91`). Input hint color is navy at 30% (`text_styles.dart:243`). Empty-state icons use slate at 60% (`empty_state.dart:24`).
- Measured: main body colors pass well. Slate `#5B6472` on paper `#F5F5F1` is **5.47:1**, and navy on paper is **13.3:1**. The weak spots are the alpha-reduced variants above. **HIG:** `foundations/accessibility.md` (4.5:1 for text up to 17 pt). **Fix:** replace alpha tricks with solid tokens and check them in a contrast tool.

#### F-11: Feedback is inconsistent and sometimes technical
- No haptics anywhere (0 `HapticFeedback`). Success is shown by editing text in place ("✓ Profile updated", "Reported ✓"). Errors sometimes expose raw exceptions (`ml_widgets.dart:396`: "Could not raise the alert: $e"). Pull-to-refresh exists on one screen only (`live_riders_screen.dart:69`). Loading is a Material spinner in 17 places, although the `shimmer` package is a dependency. **HIG:** `patterns/feedback.md`, `patterns/loading.md` ("Show something as soon as possible"), `patterns/playing-haptics.md`. **Fix:** one feedback helper (confirmation banner, error banner with retry, a light haptic on submit) and skeleton placeholders for lists.

#### F-12: Forms are missing basic input help
- Only 4 hits combined for `autofillHints`, `textInputAction` and `obscureText` in the app. The report is a 3-step wizard with no cancel confirmation. No explanation is shown before asking for location, camera or notifications, although `geolocator` and `image_picker` are used. **HIG:** `patterns/entering-data.md` (offer choices, validate as you go, use secure fields), `patterns/privacy.md`. **Fix:** add autofill hints and next/done actions, a short "why we need this" screen before each permission prompt, and a leave-without-saving confirmation on the wizard.

#### F-13: Every string is hard-coded English
- `en`, `hi`, `as` and `bn` are declared (`main.dart:72-77`), but there are 0 `AppLocalizations` uses and ~158 literal `Text('…')` calls. Header titles and subtitles are built from English strings in `field_officer_shell.dart:69-108`. **HIG:** `foundations/writing.md`, `foundations/inclusion.md`. **Impact:** field staff in Assam and Bengal see English regardless of the setting. **Fix:** move strings to ARB files and translate the top-traffic screens first.

### Low

- **F-14: Portrait-only lock and a hidden double-tap gesture.** `main.dart:15-18` locks orientation, and `app_header.dart:84` has an undocumented `onSubtitleDoubleTap`. The HIG asks that gestures have visible alternatives (`foundations/accessibility.md`, "Offer alternatives to gestures").
- **F-15: No search, and a manual offline toggle.** No search field exists (`patterns/searching.md`), and the shell has a hand-flippable `_isOffline` (`field_officer_shell.dart:41,178`) that is not driven by real connectivity. Housekeeping: `lib/mock_data/` still holds live model types (`models.dart`) and `mockRepositoryProvider`, which contradicts the "no demo data" state, so a rename is worthwhile.

---

## 4. Web app findings (`NER-Website`)

### Critical

#### W-01: Common text colors fail WCAG AA contrast
- **Evidence (computed with the WCAG relative-luminance formula):**

| Foreground | Background | Ratio | Used for | Needs |
|---|---|---|---|---|
| `#8A9098` | `#FAF7F0` (card cream) | **3.01:1** | ~149 uses: sub-labels, helper text, empty states | 4.5:1 |
| `#8A9098` | `#FFFFFF` | **3.22:1** | same | 4.5:1 |
| `#4A6A82` | `#17324D` (sidebar) | **2.30:1** | sidebar subtitle, "MAIN MENU", "System Online", Help, Logout (`Shell.tsx:205,220`) | 4.5:1 |
| `#C4861A` | `#FEF8E6` (warning badge) | **2.92:1** | status badges (`StatusBadge.tsx`) | 4.5:1 (3:1 if bold) |

- **HIG:** `foundations/accessibility.md`, "Strive to meet color contrast minimum standards": 4.5:1 for text up to 17 pt, 3:1 for bold or 18 pt and up.
- **Impact:** the sidebar is the primary navigation, and its footer controls (Help, Logout) are the hardest to read on the screen. Muted grey text carries meaning throughout the dashboard.
- **Fix:** replace `#8A9098` with a token near `#6B7280` or darker (verify at 4.5:1), and lighten sidebar secondary text to roughly `#9FB8CC` or lighter. Darken the warning-badge text. Do this once through a token (see W-03).

#### W-02: Dark mode changes only the page canvas
- **Evidence:** `lib/theme.tsx` supports light, dark and system. But `index.css:57-75` recolors only the page background and scrollbars, and its own comment says cards keep the light palette pending a token refactor. There are **0** `dark:` variants, and only `ProfilePanel.tsx` calls `useTheme`.
- **HIG:** `foundations/dark-mode.md`. The article also says to *avoid an app-specific appearance setting* and follow the system one.
- **Impact:** choosing Dark yields light cards on a dark page, which looks broken and is uncomfortable in a dim control room.
- **Fix:** either finish the migration after W-03, or remove the in-app toggle and follow the system setting until dark styles exist. Do not ship a toggle whose result looks like a bug.

#### W-03: Design tokens exist but nothing uses them
- **Evidence:** `@theme` in `index.css:15-53` defines brand, surface, text and status colors. There are **0** uses of `var(--color-…)` in TSX, against ~**1,160** hard-coded hex values and ~**964** inline `style={{}}` blocks. `pages/fo/ui.tsx` re-declares `NAVY`, `TEAL`, `GOLD`, `SURFACE` and `BORDER` as constants, and its own comment says it "mirrors the District Officer system exactly", yet the district pages don't import it.
- **HIG:** `foundations/color.md` ("Avoid hard-coding … color values"; use semantic colors that adapt), `foundations/dark-mode.md`.
- **Impact:** this is the root cause of W-01 and W-02. Any contrast or theme fix has to touch hundreds of places.
- **Fix:** define semantic tokens (`--text-secondary`, `--surface-card`, `--border`, `--status-warning-fg/bg`) with light and dark values, then replace the hex values page by page, starting with `Shell.tsx`, `StatusBadge.tsx` and `fo/ui.tsx`.

### High

#### W-04: Icon-only buttons have no accessible name, and icons are text glyphs
- **Evidence:** `Shell.tsx` contains **0** `aria-*` attributes. The sidebar toggle `≡`, field-officer alert bell `◬` and Help close `✕` (`Shell.tsx:~314,~343,~416`) are unlabeled. Only one control in the file has a `title` (`Shell.tsx:351`). The sidebar icons (`⊞ ◉ ◆ ☑ ✦ ◬ ✓ ⊡ ▨`) are plain Unicode with no `aria-hidden`. Across the app there are only ~10 `aria-label`s. Outside `auth/Icons.tsx` there are no SVG icons.
- **HIG:** `foundations/icons.md` (alternative text labels), `foundations/sf-symbols.md` (consistent, weight-matched symbols), `foundations/accessibility.md`.
- **Impact:** screen readers announce "black square with cross" or nothing for controls that operate the whole shell. The glyphs also look different on macOS, Windows and Android.
- **Fix:** adopt one SVG icon set (for example Lucide or Phosphor, both tree-shakable), add `aria-label` to every icon-only button, `aria-expanded` to the sidebar toggle, and `aria-hidden` to decorative glyphs.

#### W-05: Modals and drawers lack dialog semantics and focus management
- **Evidence:** ~11 `<div onClick>` backdrops (`Shell.tsx:411`, `ProfilePanel.tsx:588`, `Incidents.tsx:39,148`, `Routes.tsx:10`, `fo/Reports.tsx:96`, `CommandCenter.tsx:540`). Escape closes only `ProfilePanel` and `ChatPanel`. The Help modal, the Incidents and Routes drawers, the evidence preview and the Reports and Command Center overlays have no `role="dialog"`, `aria-modal`, focus trap or focus return. There are **5** variants, with backdrops at 20/30/35/40/70% opacity and differing radii.
- **HIG:** `patterns/modality.md` ("Always give people an obvious way to dismiss a modal view"), `components/presentation/sheets.md`.
- **Impact:** keyboard users can tab behind an open panel, and screen-reader users are not told a dialog opened.
- **Fix:** build one `Modal`/`Drawer` primitive (native `<dialog>` is the smallest option) with Escape, focus trap, focus return and a single scrim style, then replace the five variants.

#### W-06: Small pointer and touch targets
- **Evidence:** header icon buttons `w-8 h-8` (32 px, `Shell.tsx:~314,~343`), `GhostBtn` about 28 px tall (`fo/ui.tsx:~40`), Chat and Help close buttons `px-2 py-1`, Leaflet map controls 32 px (`index.css:~206`), and table row actions (`Incidents.tsx:~360`). Only `PrimaryBtn` sets `minHeight: 44`.
- **HIG:** `foundations/accessibility.md`: macOS default **28×28**, minimum **20×20**. iOS and iPadOS default **44×44**, minimum **28×28**.
- **Impact:** 28 to 32 px is acceptable for a mouse on macOS, but this dashboard has a field-officer role that is likely used on tablets and phones, where these targets are too small.
- **Fix:** keep 32 px on `pointer: fine` devices and raise to 44 px under `@media (pointer: coarse)`. `PrimaryBtn`'s `minHeight: 44` is the model to apply.

#### W-07: Focus indicators are missing for many controls
- **Evidence:** the global rule at `index.css:132` covers only `button`, `a` and `input`. It does not cover `select`, `textarea` or `[role=button]`. `.glass-field` (`src/auth.css:102`) sets `outline: none` and changes only the border color. `outline-none` appears on inputs in `ProfilePanel.tsx:37,54`, `Analytics.tsx:250,266` and `fo/ReportIncident.tsx:267-339`. There are 14 `outline: none` usages in total.
- **HIG:** `foundations/accessibility.md` ("Let people use the keyboard alone to navigate and interact with your app"), `foundations/color.md` ("Avoid using only color to indicate focus").
- **Fix:** replace the list with `:focus-visible { outline: 2px solid … }` on all interactive elements and remove `outline-none` unless a replacement ring is set.

#### W-08: Navigation has no URLs, no mobile pattern and a fixed sidebar
- **Evidence:** dashboard pages are switched by a `page` state string in `App.tsx:~235-260`. Only auth screens and `/dashboard/{role}` have URLs, so there are no deep links and browser Back does not move between pages. The sidebar is a fixed 244 px that collapses to 0 with a header button, with no overlay behavior on small screens (about 52 breakpoint classes in the whole app). Below `sm` the header hides the user name, role and status pills.
- **HIG:** `components/navigation-and-search/sidebars.md`, `getting-started/designing-for-ipados.md`, `getting-started/designing-for-macos.md`.
- **Impact:** people cannot bookmark or share a page, or use Back. On an iPad the sidebar either eats a quarter of the screen or vanishes.
- **Fix:** adopt a small router (for example React Router) for the existing page keys. Make the sidebar an overlay drawer below the `md` breakpoint. Give the breadcrumb `aria-label="Breadcrumb"` and `aria-current`.

#### W-09: Text below 11 px
- **Evidence:** inline `fontSize: 9` and `10` (~13 uses) plus `text-[10px]` and `text-[11px]` (~6 uses), including the breadcrumb, sidebar labels (`Shell.tsx:205,220,319,333,360,385`), the incident timeline (`Incidents.tsx:82`), the ML badge (`MlRisk.tsx:29`) and the map note (`MapViz.tsx:572`). The default size is `text-xs` (12 px) in 422 places and `text-sm` (14 px) in 131 places, with no defined type scale.
- **HIG:** `foundations/typography.md`: on macOS the default is 13 pt and the minimum 10 pt. On iOS and iPadOS the default is 17 pt and the minimum 11 pt.
- **Impact:** 9 to 10 px, in low-contrast colors (W-01), is the least legible text in the app, and it carries labels and status.
- **Fix:** set a floor of 12 px, use `rem` so browser zoom and text-size settings scale it, and define 5 to 6 named sizes.

### Medium

- **W-10: Form controls lack labels.** The filter `<select>`s in `Incidents.tsx:312,319`, `Reports.tsx:181-219`, `Analytics.tsx:246,262` and `Routes.tsx:127` have no label, and the field-officer report inputs (`fo/ReportIncident.tsx:267-339`) sit in wrapper divs with no `htmlFor` association. "Forgot password?" is `href="#"` (`LoginTab.tsx`). None of the 9 `<table>`s uses `<th scope>`. **HIG:** `patterns/entering-data.md`, `foundations/accessibility.md`.
- **W-11: Card hover-lift on non-interactive cards.** `index.css:197-198` lifts every `main .rounded-xl.border` by 2 px with a shadow on hover, including cards that do nothing. That signals clickability that isn't there. **HIG:** `foundations/motion.md` (motion should be purposeful). **Fix:** apply the lift only to cards that are links or buttons.
- **W-12: Two design languages.** The login and splash use custom SVG "liquid glass" with Public Sans and Noto Sans (`src/auth.css`, `auth/GlassFilters.tsx`), while the dashboard uses Inter on cream cards, and the login submit is `#0E2A47` with a 4 px radius against `#17324D` in the app. The SVG-displacement `backdrop-filter: url(#…)` is Chromium-specific and needs a Safari fallback check. **HIG:** `foundations/materials.md` (use glass sparingly, and only where it aids hierarchy). **Fix:** test in Safari, and pick one type family and one navy.
- **W-13: Feedback patterns.** No toast or banner system exists, and there is no undo. The only destructive confirmation is `window.confirm` when rejecting an account request (`Approvals.tsx:53`). Logout has none. **HIG:** `patterns/feedback.md`, `components/presentation/alerts.md`. **Fix:** a small inline banner or toast component, and a real confirmation dialog through the W-05 primitive.
- **W-14: Empty and loading states are thin.** Empty states are centered grey text with no icon or next action (`Logistics.tsx:62,113`, `FieldOfficerDashboard.tsx:328`, `fo/Reports.tsx:91`, `Analytics.tsx:368`). `.ui-skeleton` is defined but not used, and loading is text ("Loading requests…") or one full-screen spinner. **HIG:** `patterns/loading.md`. **Model:** the ML notices in `MlRisk.tsx:74-91` already explain what happened and what to do.
- **W-15: Search is missing.** No search input anywhere, and filtering is by native `<select>` and tab chips. For pages with long incident, report and task tables this is a real gap. **HIG:** `patterns/searching.md`, `components/navigation-and-search/search-fields.md`.
- **W-16: Document shell and font loading.** `index.html:2` ships `lang="<!-- figma:lang -->"` (verified). The runtime fixes it in `lib/i18n.tsx:117`, but crawlers and the first paint see the placeholder. There is no `theme-color` and no meta description, and the title has a trailing space. Inter loads from the Google Fonts CDN with a bare `sans-serif` fallback. **Fix:** set `lang="en"`, and use `-apple-system, BlinkMacSystemFont, "Inter", …` so Apple devices render SF when the CDN is slow.

### Low

- **W-17: Language coverage.** Six languages are selectable, but only English and Hindi are translated, and many pages skip `t()` (`Approvals`, `Incidents`, `Reports`, the field-officer and control pages, `App.tsx` error text). Contact details are hard-coded (`Shell.tsx:~420`).
- **W-18: Chat panel placement.** `ChatPanel` sits at `fixed bottom-5 right-5` with no safe-area inset, and it can cover table content and page actions. Its dialog semantics (`aria-live`, Escape, `aria-expanded`) are good.
- **W-19: Dead code and tooling.** `src/auth-dedicated/` duplicates `src/auth/`, `App.tsx:262-300` repeats the same error screen, and there is no ESLint, a11y lint or test setup, so regressions in this audit would not be caught.

---

## 5. What is already good

**Flutter**
- Strong text contrast in the core palette: navy on paper is 13.3:1, and slate on paper is 5.47:1.
- Risk levels are communicated with color, icon and text together, as the HIG asks (`theme/colors.dart:3-4`).
- Clear empty-state widget (`shared/widgets/empty_state.dart`), used in 10 places, and an offline banner.
- Real authentication, edge-to-edge layout, and bundled fonts with a consistent hierarchy.

**Web**
- `prefers-reduced-motion` is respected (`index.css:249-255`, and the login transition skips itself).
- Pinch-zoom is allowed (no `user-scalable=no`).
- `ChatPanel` is the best-built component: proper `role="dialog"`, `aria-live` and `aria-busy` on the message stream, Escape to close and `aria-expanded`.
- The login form has real labels and `role="alert"` errors, and the show-password toggle is labeled.
- The ML risk notices (`MlRisk.tsx:74-91`) have good, actionable error and empty copy.
- `PrimaryBtn` already enforces a 44 px minimum.
- Severity badges pair color with a text label and glyph rather than color alone.

---

## 6. Remediation roadmap

Effort labels are rough guides: **S** = under a day, **M** = 1 to 3 days, **L** = a week or more.

### Phase 1: quick wins (about 1 to 2 days)

| Item | Finding | Effort |
|---|---|---|
| Replace `#8A9098`, `#4A6A82` and warning-badge text with AA-passing colors, via one token each | W-01 | S |
| Add `aria-label` to the header and sidebar icon buttons; `aria-hidden` on decorative glyphs | W-04 | S |
| Fix `<html lang>`; add the `-apple-system` font fallback | W-16 | S |
| Extend `:focus-visible` to `select`, `textarea` and `[role=button]`; stop removing outlines | W-07 | S |
| Add `Semantics` to `NerToggle`, header buttons and report cards | F-01 | S |
| Sign-out confirmation when there is unsynced data | F-08 | S |
| Restrict card hover-lift to clickable cards | W-11 | S |
| Stop or slow the splash rotation under Reduce Motion | F-09 | S |
| Remove or hide the in-app dark toggle until dark styles exist | W-02 | S |

### Phase 2: foundations (about 1 to 3 weeks)

| Item | Finding | Effort |
|---|---|---|
| Flutter: semantic type scale, 11 sp floor, `textScaler` clamp, remove fixed heights | F-02 | M |
| Flutter: enforce `kMinInteractiveDimension` on all controls | F-03 | M |
| Flutter: replace emoji with a consistent icon set | F-04 | M |
| Flutter: remove the fake status bar | F-06 | S |
| Web: wire tokens into components, starting with `Shell`, `StatusBadge`, `fo/ui.tsx` | W-03 | L |
| Web: one `Modal`/`Drawer` primitive with focus management | W-05 | M |
| Web: shared `Button`, `Field`, `Select`, `EmptyState`, `Toast` primitives, with labels | W-10, W-13, W-14 | M |
| Web: SVG icon set replacing glyphs | W-04 | M |
| Web: 44 px targets on touch devices; 12 px text floor | W-06, W-09 | S |
| Both: feedback helper (confirmation, error with retry, haptic or toast, skeletons) | F-11, W-13, W-14 | M |

### Phase 3: structural (multi-week)

| Item | Finding | Effort |
|---|---|---|
| Flutter: bottom navigation bar and route-based screens with a real bottom sheet | F-07 | L |
| Flutter: `ColorScheme` with a dark scheme | F-05 | L |
| Web: real dark mode built on semantic tokens | W-02, W-03 | L |
| Web: router with URLs and a responsive sidebar drawer | W-08 | M |
| Both: externalize strings and translate the core screens (ARB and `t()`) | F-13, W-17 | L |
| Both: add search to the long lists | F-15, W-15 | M |
| Both: accessibility CI: `eslint-plugin-jsx-a11y` and axe for web, semantics and golden tests at 200% text for Flutter | W-19 | M |

### Phase 4: verify (do this before calling the audit closed)

1. Run VoiceOver on an iPhone through the Flutter app's login, report and alerts flows.
2. Set Larger Accessibility Text to the maximum and confirm nothing clips or overlaps.
3. Run Accessibility Inspector, Lighthouse and axe against the web dashboard for all three roles.
4. Test Dark Mode, Increase Contrast and Reduce Motion on both apps.
5. Test the web login in Safari for the liquid-glass filter fallback.
6. Re-measure the touch targets on a device instead of relying on declared sizes.

---

## 7. Appendix

### A. Metrics

| Metric | Flutter | Web |
|---|---|---|
| Source files reviewed | 105 Dart | ~70 TS/TSX/CSS |
| `Semantics` / `aria-*` | 3 `Semantics` | ~27 `aria-*` (10 `aria-label`, 8 `role=`) |
| Tooltips / `title` | 7 | few |
| Font-size literals outside the theme | 80 (33 at ≤12) | ~13 inline at 9–10, plus ~6 `text-[10/11px]` |
| Dark-mode-aware styles | 0 (no `darkTheme`) | 0 `dark:` variants, canvas-only toggle |
| Token usage vs hard-coded colors | tokens exist, 246 opacity tweaks | 0 token uses vs ~1,160 hex |
| Dialogs / confirmations | 0 dialogs | 1 (`window.confirm`) |
| Modal/sheet variants | 2 sheets + 1 custom overlay | 5 modal/drawer variants |
| Haptics | 0 | n/a |
| Search fields | 0 | 0 |
| Icon system | 259 Material `Icons.*` + emoji | Unicode glyphs |
| Reduce-motion handling | none | yes |
| Localization | 4 locales declared, 0 used | 6 languages, 2 translated |

### B. Contrast calculations

Computed with the WCAG 2.x relative-luminance formula, the standard behind the 4.5:1 and 3:1 thresholds cited in `foundations/accessibility.md`.

| Pair | Ratio | Passes 4.5:1? |
|---|---|---|
| Web `#8A9098` on `#FAF7F0` | 3.01 | No |
| Web `#8A9098` on `#FFFFFF` | 3.22 | No |
| Web `#4A6A82` on `#17324D` | 2.30 | No |
| Web `#C4861A` on `#FEF8E6` | 2.92 | No |
| Flutter slate `#5B6472` on paper `#F5F5F1` | 5.47 | Yes |
| Flutter navy `#0E2A47` on paper `#F5F5F1` | 13.33 | Yes |

Not measured: alpha-blended colors (`white54/70`, navy at 30%), which depend on what sits behind them.

### C. HIG references used

All under `apple-design-skill/references/`:

`foundations/accessibility.md`, `foundations/typography.md`, `foundations/color.md`, `foundations/dark-mode.md`, `foundations/layout.md`, `foundations/icons.md`, `foundations/sf-symbols.md`, `foundations/materials.md`, `foundations/motion.md`, `foundations/writing.md`, `foundations/inclusion.md`, `components/navigation-and-search/tab-bars.md`, `components/navigation-and-search/sidebars.md`, `components/navigation-and-search/search-fields.md`, `components/presentation/alerts.md`, `components/presentation/sheets.md`, `components/selection-and-input/toggles.md`, `patterns/modality.md`, `patterns/feedback.md`, `patterns/loading.md`, `patterns/entering-data.md`, `patterns/searching.md`, `getting-started/designing-for-ios.md`, `getting-started/designing-for-ipados.md`, `getting-started/designing-for-macos.md`.

Articles I have not read in full are cited only for the specific rule quoted in the search results, so treat those citations as pointers and confirm them against the article before quoting them elsewhere.

### D. Notes on interpretation

- The HIG describes design intent for native Apple platforms. Flutter and React have their own idioms (for example, Material-style controls are not "wrong" on their own), so findings focus on outcomes the HIG protects: legibility, target size, screen-reader access, consistency and user control.
- The launch-screen guidance (`patterns/launching.md`: no text, no branding) applies to the OS launch storyboard, not to the app's in-app welcome screen, so it is not counted against the splash screen here.
- Counts marked `~` are search-based and should be treated as approximate.
