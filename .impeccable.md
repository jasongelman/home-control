# Lutron Home — Design Context

## Users

Two tech-savvy adults sharing a single-household smart home app. Both are comfortable with dense information and direct device control. Optimize for speed and information density over hand-holding — but keep things self-explanatory so either person can act without thinking.

## Brand Personality

**Sleek, powerful, dense.** The app should feel like a premium instrument panel — every pixel earns its place. Information is the interface. The house itself is the brand.

## Aesthetic Direction

**Reference:** Flighty / Carrot Weather — dense data beautifully presented, personality expressed through the data visualization itself rather than decoration.

**Visual tone:** Dark-only. Glass-morphism materials (`.ultraThinMaterial`) over dark backgrounds. Time-aware color shifting via `SunCalculator.TimeTheme` gives the app a living, ambient quality — lean into this. Orange is the primary accent; integration-specific colors (cyan, indigo, teal, green) provide semantic meaning. Status is expressed through color, not through labels saying "status."

**Anti-references:** Skeuomorphism, playful/rounded UI (Notion, Linear), light/airy dashboards, gratuitous animations, empty states that waste space. Never decorative — every element communicates something.

## Design Principles

1. **Information density over whitespace.** Show more, not less. Two tech-savvy users want to see the whole house at a glance. A well-designed dense layout beats a pretty sparse one. When in doubt, add the data point.

2. **Color is semantic, not decorative.** Green = safe/off. Orange = armed/active/accent. Red = alarm/error. Cyan/indigo/purple = appliance types. Teal = climate. Yellow = lights on. Never use color without meaning. The time-aware theme is the one place color is atmospheric — everywhere else it carries information.

3. **Materials over borders.** Use `.ultraThinMaterial` and subtle opacity layers to create hierarchy. Avoid hard borders and drop shadows. Cards emerge from the background through material contrast, not outlines. The `0.5pt` separator stroke is a ceiling, not a floor.

4. **Animate only what changes.** `.symbolEffect(.pulse)` for active/transitioning states. `.easeOut(0.15s)` for direct-manipulation drags. No entrance animations, no stagger effects, no spring physics. Motion communicates state change, not personality.

5. **Parity without mimicry.** iOS and web must expose the same capabilities, but each should feel native to its platform. SwiftUI idioms on iOS (sheets, NavigationStack, SF Symbols). MUI idioms on web (dialogs, drawers, MUI icons). Same data, different expression.

## Design Tokens

| Token | iOS | Web |
|-------|-----|-----|
| Primary accent | `.orange` / TimeTheme accent | `#f5a623` |
| Background | System dark (forced) | `#121212` |
| Card surface | `.ultraThinMaterial` | `#1e1e1e` + `rgba(255,255,255,0.08)` border |
| Border radius (cards) | `12pt` | `12px` |
| Border radius (large) | `14pt` | — |
| Border radius (small) | `8pt` | `8px` |
| Touch target min | `56pt` height | `48px` height |
| Card padding | `12–14pt` | `16px` (2 MUI units) |
| Section gap | `20–24pt` | `24px` (3 MUI units) |
| Element gap | `8–10pt` | `8–12px` |
| Icon size (inline) | `14–16pt` | `14px` |
| Icon size (small) | `9–11pt` | `10–11px` |
| Body text | `.footnote` (13pt) | `0.875rem` |
| Caption text | `.caption` (12pt) | `0.75rem` |
| Easing (interaction) | `.easeOut(0.15s)` | `0.15s ease-out` |
| Easing (expand) | `.easeInOut(0.25s)` | `0.25s cubic-bezier(0.4,0,0.2,1)` |

## Typography Hierarchy

| Level | iOS | Web | Usage |
|-------|-----|-----|-------|
| Display | `.largeTitle` bold | — | Dashboard title ("8 Highclere") |
| Heading | `.title2` semibold | `h5` 700 | Sheet/detail headers |
| Subhead | `.subheadline` | `subtitle1` | Greeting, secondary header |
| Section label | `.caption` semibold, uppercase, `.tracking(0.5)` | `subtitle2` 600, uppercase, `0.06em` | Section headers |
| Body | `.footnote` semibold | `body2` | Card titles, button labels |
| Detail | `.caption` / `.caption2` | `caption` | Status text, timestamps |
| Monospace | `.system(size: 10, design: .monospaced)` | `font-variant-numeric: tabular-nums` | Countdowns, percentages |

## Color Semantics

| Meaning | Color | Usage |
|---------|-------|-------|
| Safe / off / disarmed | `.green` | Alarm disarmed, doors closed |
| Active accent / armed | `.orange` | Primary accent, alarm armed, contextual actions |
| Alert / alarm | `.red` | Alarm triggering, errors |
| Lights on | `.yellow` | Light status indicators |
| Dishwasher / HomeConnect | `.cyan` | Dishwasher status and controls |
| Washer / SmartHQ | `.indigo` | Washer status |
| Dryer / SmartHQ | `.purple` | Dryer status |
| Climate / heat pump | `.teal` | Heat pump, fans |
| Garage moving | `.yellow` | Door in transition |
| Secondary / idle | `.secondary` | Inactive/off states |
