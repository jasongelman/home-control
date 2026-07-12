---
name: Lutron Home
description: A single household's whole-home control surface, typeset like a morning newspaper on iOS and lit like a night desk on the web
colors:
  ink-orange: "#ED5B21"
  ink-black: "#000000"
  paper-white: "#FFFFFF"
  paper-gray: "#F2F2F7"
  ink-secondary: "#3C3C4399"
  ink-tertiary: "#3C3C434D"
  hairline: "#C6C6C84D"
  cooling-blue: "#3399F2"
  idle-gray: "#D1D1D6"
  hero-early-morning: "#8C59D9"
  hero-morning: "#F2A626"
  hero-midday: "#268CE6"
  hero-night: "#66A6FF"
  panel-amber: "#F5A623"
  panel-amber-deep: "#C17B00"
  panel-blue: "#4A9EDA"
  panel-bg: "#121212"
  panel-surface: "#1E1E1E"
  panel-border: "#FFFFFF14"
  panel-text: "#E0E0E0"
  panel-text-dim: "#888888"
typography:
  display:
    fontFamily: "BebasNeue-Regular, system-ui-condensed, sans-serif"
    fontSize: "48px"
    fontWeight: 400
    lineHeight: 1
  section-label:
    fontFamily: "-apple-system, SF Pro Text, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    letterSpacing: "1.2px"
  micro-label:
    fontFamily: "-apple-system, SF Pro Text, sans-serif"
    fontSize: "9px"
    fontWeight: 500
    letterSpacing: "0.8px"
  mono-value:
    fontFamily: "SF Mono, ui-monospace, monospace"
    fontSize: "12px"
    fontWeight: 700
  body:
    fontFamily: "-apple-system, SF Pro Text, sans-serif"
    fontSize: "13px"
    fontWeight: 600
  panel-body:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, sans-serif"
    fontSize: "14px"
    fontWeight: 400
rounded:
  none: "0px"
  card: "8px"
  panel-button: "8px"
  panel-card: "12px"
spacing:
  grid: "10px"
  section: "24px"
  pill-pad: "10px"
  panel-card-pad: "16px"
components:
  dimmable-pill:
    backgroundColor: "{colors.paper-gray}"
    textColor: "{colors.ink-black}"
    typography: "{typography.micro-label}"
    rounded: "{rounded.none}"
    height: "40px"
    padding: "0 10px"
  section-header:
    textColor: "{colors.ink-black}"
    typography: "{typography.section-label}"
  header-action:
    textColor: "{colors.ink-orange}"
    typography: "{typography.micro-label}"
  editorial-card:
    backgroundColor: "{colors.paper-white}"
    rounded: "{rounded.card}"
    padding: "12px"
  panel-card:
    backgroundColor: "{colors.panel-surface}"
    textColor: "{colors.panel-text}"
    rounded: "{rounded.panel-card}"
    padding: "{spacing.panel-card-pad}"
  panel-light-pill:
    backgroundColor: "#FFFFFF0A"
    textColor: "{colors.panel-amber}"
    rounded: "{rounded.panel-button}"
    height: "36px"
---

# Design System: Lutron Home

## 1. Overview

**Creative North Star: "The Morning Broadsheet"**

The home is rendered as a beautifully typeset newspaper front page. The masthead greets by time of day ("MORNING LIGHT.", "GOODNIGHT HOUSE."), the dateline reads "HOME · N°40.93" like a paper's coordinates, sections open with small tracked capitals and a right-aligned count ("LIGHTS ON …… 8 ACTIVE"), and every figure is set in bold monospace like a stock table. Data is the news; typography is the entire decoration budget. Components are **typeset, not drawn**: hairline rules, sharp rectangles, and fills that behave like ink coverage stand in for borders, shadows, and chrome.

The system has two deliberate platform expressions, per PRODUCT.md's "parity without mimicry." **iOS is the Morning Edition**: black ink on white paper, Ink Orange as the second color on the press. **Web is the Night Desk**: the same dense, data-first instrument read against `panel-bg` (#121212) with amber (#F5A623) as its working light, built in MUI idiom. Same capabilities, same density, different paper stock. Neither is a port of the other; a feature ships when it reads natively in both.

The system explicitly rejects skeuomorphism, playful rounded-friendly UI, gratuitous animation, and empty states that waste space. Nothing is decorative; if an element carries no information, it does not print.

**Key Characteristics:**
- Information density over whitespace: show the whole house at a glance
- Typography-first: hierarchy from tracked caps, condensed display, and mono figures, not boxes
- Flat as the page: zero shadows on iOS; depth is ink, not light
- Color is semantic, never mood (the one exception: the time-aware hero accent)
- Direct manipulation: the control IS the readout (drag the pill, the fill is the value)

## 2. Colors

Two inks on paper for iOS; amber light on a dark desk for web. Everything else is data speaking.

### Primary
- **Ink Orange** (#ED5B21): the second ink. Active fills (at 15% opacity), the 2px brightness marker, text actions ("ALL OFF", "TALK TO ME"), active status icons, heating, and the hero word in the evening. It marks *what is live and what you can act on*, never decoration.
- **Panel Amber** (#F5A623, deep #C17B00): Ink Orange's night-shift equivalent on web. Same jobs: active fills at ~32% opacity, light pills, primary actions.

### Secondary
- **Cooling Blue** (#3399F2) / **Panel Blue** (#4A9EDA): cooling state on climate bars (iOS / web respectively). Blue always means cold, never brand.
- **Hero accents** (time-aware, iOS masthead only): early morning #8C59D9, morning #F2A626, midday #268CE6, evening Ink Orange, night #66A6FF. The single place color is atmospheric.

### Neutral
- **Paper White** (#FFFFFF) / **Ink Black** (#000000): iOS ground and primary text. This system intentionally runs true white and true black; it is print, not a tinted app surface.
- **Paper Gray** (#F2F2F7, systemGray6): pill and cell ground; the unprinted portion of a fill.
- **Ink Secondary / Ink Tertiary** (system secondary/tertiary label): datelines, room labels, drained "off" pill titles.
- **Hairline** (separator at 30%, drawn at 0.5pt): every rule and border on iOS.
- **Idle Gray** (#D1D1D6): climate bars at rest.
- **Panel Bg / Panel Surface / Panel Border / Panel Text** (#121212 / #1E1E1E / rgba(255,255,255,0.08) / #E0E0E0): the web desk. Green #4CAF50, red #F44336 keep their universal safe/alarm meanings on both platforms.

### Named Rules
**The Two-Ink Rule.** The iOS page prints in black and Ink Orange. Any third color on screen must be carrying a semantic payload (cooling, safe, alarm, appliance state) or the time-aware masthead. A color with no meaning is forbidden.

**The Live-Ink Rule.** Ink Orange marks what is active or actionable *right now*. Never use it on idle, historical, or purely informational elements; those are black, secondary, or gray.

## 3. Typography

**Display Font:** Bebas Neue (registered in-app, `EditorialTheme.bebasNeue`)
**Body Font:** SF Pro system stack (iOS) / -apple-system system stack (web)
**Mono Font:** SF Mono via `.system(design: .monospaced)` (iOS) / `tabular-nums` (web)

**Character:** A condensed newspaper masthead over wire-service capitals and stock-table figures. Loud exactly once per screen; precise everywhere else.

### Hierarchy
- **Display** (Bebas Neue 400, 48pt, single line): the hero greeting only. Two words, second word in the time-aware accent.
- **Section label** (600, 11pt, tracking 1.2, UPPERCASE): section openers ("LIGHTS ON", "STATUS"), always paired with a right-aligned trailing count in 10pt secondary.
- **Micro label** (500–600, 9–10pt, tracking 0.4–1.0, UPPERCASE): room names, device names, datelines, status-cell captions. The workhorse of the entire UI.
- **Mono value** (bold, 10–12pt, monospaced): every number: percentages, temperatures, amps, counts. Numbers are never set in the text face.
- **Body** (600, 13pt / `.footnote`): sentence-case supporting copy, sparse by design.
- **Panel body** (400–600, 14px, MUI `body2`/`subtitle2`): web equivalent; `subtitle2` is uppercase, 600, 0.06em tracked for section headers.

### Named Rules
**The Masthead Rule.** Bebas Neue appears exactly once per screen, in the hero. Everywhere else is tracked capitals at 9–11pt. A second display-size element would make two front pages.

**The Stock-Table Rule.** Every numeral renders in bold mono (or `tabular-nums` on web). If a number is proportionally spaced, it's a bug.

## 4. Elevation

Flat as the page. iOS uses **no shadows anywhere**: hierarchy comes from the 0.5pt hairline, paper-gray fills against paper white, and typography scale. Depth is ink coverage, not light. Web is equally flat at rest (1px `panel-border` on `panel-surface` cards, `backgroundImage: none` everywhere); its single sanctioned glow is the slider thumb on hover/focus (`0 0 12px rgba(245,166,35,0.4)`), a fingertip of lamplight on the night desk.

### Named Rules
**The No-Shadow Rule.** If a surface needs to feel separate on iOS, give it a hairline or a paper-gray fill. `box-shadow`/`.shadow()` is prohibited. On web, any shadow other than the slider-thumb glow is prohibited.

## 5. Components

Typeset, not drawn: each component is a rectangle of set type whose background does the talking.

### Dimmable Pill (signature component)
The atom of light control. A sharp 40pt rectangle (radius 0), paper-gray ground, 0.5pt hairline, name in micro-label caps on the left, mono percentage on the right. The Ink Orange fill at 15% opacity spans exactly `level%` of the width, capped by a 2px solid Ink Orange marker: the fill is the value, the marker is the needle. Tap toggles 0↔100; horizontal drag scrubs brightness live (`.easeOut 0.15s`, animation suppressed during drag). A turned-off pill lingers in place, drained and dimmed to tertiary ink, tappable to undo; the section compacts only after ~2.5s of stillness so rapid one-by-one taps never shift the layout. Web `LightOnPill` is the same instrument at 36px, radius 8, amber fill at 32%.

### Section Header
`SECTION NAME` in section-label caps, hairline-free, with a right-aligned mono/label count ("8 ACTIVE") in secondary ink. Optional text action ("ALL OFF") sits before the count in Ink Orange micro-label caps: plain text, no button chrome.

### Cards / Containers
- **Corner Style:** 8pt on iOS (`editorialCard`), 12px on web.
- **Background:** paper white (iOS) / panel surface (web).
- **Border:** 0.5pt hairline (iOS) / 1px `panel-border` (web). Full-perimeter only.
- **Shadow Strategy:** none (see Elevation).
- **Internal Padding:** 12–14pt (iOS), 16px (web). Most content does NOT get a card; sections sit directly on the page and cards are reserved for genuinely contained things (camera feeds, detail sheets).

### Status Cells
3-column grid of flat cells: 11pt icon (Ink Orange when active, secondary when idle), 9pt uppercase caption, mono value. Active state is color, not badge.

### Masthead / Top Bar
Connection dot (green/red, 6pt), "HOME · N°40.93" dateline and date in 10pt tracked caps secondary, "TALK TO ME" text action in Ink Orange. Below it, the Bebas Neue greeting.

### Buttons
There are almost no drawn buttons on iOS: actions are typeset words in Ink Orange caps (`.buttonStyle(.plain)`). Web buttons are MUI outlined, radius 8, weight 600, no text-transform, hover lifting `translateY(-1px)` with an amber-tinted background: the one platform where buttons get chrome.

### Motion (applies per component)
`.easeOut 0.15s` for direct-manipulation feedback; `.easeInOut 0.25s` (`cubic-bezier(0.4,0,0.2,1)` on web) for structural changes like the lights-section compaction. `.symbolEffect(.pulse)` for in-transition states. No entrance animations, no stagger, no springs.

## 6. Do's and Don'ts

### Do:
- **Do** set every number in bold mono / `tabular-nums`, uppercase every label, and keep tracking between 0.4 and 1.2.
- **Do** make the control the readout: fills and markers that ARE the value (pill fill = brightness, bar = climate state).
- **Do** hold layout still during rapid interaction: defer removals (~2.5s settle), keep sticky column assignments, animate compaction once at `.easeInOut 0.25s`.
- **Do** add the data point when in doubt; density is the brand ("show more, not less" per PRODUCT.md).
- **Do** express state through color with fixed meanings: Ink Orange/amber = active/actionable, blue = cooling, green = safe, red = alarm, gray = idle.

### Don't:
- **Don't** use skeuomorphism, playful/rounded UI (Notion, Linear), or light-and-airy sparse dashboards; those are PRODUCT.md's named anti-references.
- **Don't** draw shadows on iOS or any web shadow beyond the slider-thumb glow. No `.ultraThinMaterial`, no glassmorphism, no gradients: the old dark glass theme is retired.
- **Don't** use entrance animations, staggers, springs, or bounce. Motion communicates state change, not personality.
- **Don't** round the Dimmable Pill or status cells on iOS; sharp corners are the print signature. Cards cap at 8pt.
- **Don't** put Ink Orange on idle or informational elements, and never introduce a meaningless accent color (The Two-Ink Rule).
- **Don't** set Bebas Neue anywhere but the hero (The Masthead Rule).
- **Don't** wrap sections in cards by default; the page IS the container. If it looks like a grid of identical SaaS cards, it has failed.
- **Don't** waste space on empty states; collapse empty sections entirely (the lights section removes itself when nothing is on).
