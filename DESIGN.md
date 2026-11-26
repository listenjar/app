---
name: ListenJar app
description: The app's layer on ListenJar's brand core; at rest each show's artwork leads like a record sleeve, and on scroll the chrome folds into glass.
colors:
  # Mirrors of the brand core (root DESIGN.md); change them there first.
  ink: "#0a0b0f"
  snow: "#f3f4f7"
  snow-soft: "#a5a8b6"
  accent: "#5165ee"
  accent-light: "#8f9cff"
  ink-tile: "rgb(255 255 255 / 0.05)"
  mist: "#eef0fd"
  glass-dark: "rgb(14 15 20 / 0.82)"
  glass-light: "rgb(255 255 255 / 0.80)"
  glass-clear: "rgb(14 15 20 / 0.40)"
  # The app's own.
  glass-on-ink: "rgb(255 255 255 / 0.12)"
  glow-fallback: "#6a55f0"
typography:
  sleeve-title:
    fontFamily: "system-ui"
    fontSize: "28px"
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: "-0.03em"
  sleeve-title-wide:
    fontFamily: "system-ui"
    fontSize: "40px"
    fontWeight: 700
    lineHeight: 1.08
    letterSpacing: "-0.03em"
  sleeve-kicker:
    fontFamily: "system-ui"
    fontSize: "14px"
    fontWeight: 600
    lineHeight: 1.3
  bar-title:
    fontFamily: "system-ui"
    fontSize: "17px"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.02em"
  tab-label:
    fontFamily: "system-ui"
    fontSize: "12px"
    fontWeight: 600
    lineHeight: 1
rounded:
  artwork-row: "12px"
  artwork-shelf: "18px"
  artwork-header: "18px"
  sheet: "22px"
  full: "9999px"
spacing:
  chrome-inset: "16px"
  chrome-gap: "8px"
  control: "44px"
  tab-pill: "64px"
  tab-folded: "52px"
  accessory: "56px"
  bar: "52px"
  fold-travel: "56px"
  bar-travel: "48px"
  wide: "760px"
components:
  glass-button:
    backgroundColor: "{colors.glass-clear}"
    textColor: "{colors.snow}"
    rounded: "{rounded.full}"
    size: "44px"
  glass-cluster:
    backgroundColor: "{colors.glass-clear}"
    textColor: "{colors.snow}"
    rounded: "{rounded.full}"
    height: "44px"
    padding: "0 6px"
  title-bar:
    backgroundColor: "{colors.glass-dark}"
    textColor: "{colors.snow}"
    typography: "{typography.bar-title}"
    height: "52px"
  play-pill:
    backgroundColor: "{colors.accent}"
    textColor: "#ffffff"
    rounded: "{rounded.full}"
    height: "48px"
    padding: "0 20px 0 16px"
  sleeve-circle:
    backgroundColor: "{colors.ink-tile}"
    textColor: "{colors.accent-light}"
    rounded: "{rounded.full}"
    size: "48px"
  tab-pill-ink:
    backgroundColor: "{colors.glass-dark}"
    textColor: "{colors.snow-soft}"
    typography: "{typography.tab-label}"
    rounded: "{rounded.full}"
    height: "64px"
  tab-pill-ink-selected:
    backgroundColor: "{colors.ink-tile}"
    textColor: "{colors.accent-light}"
  tab-pill-paper:
    backgroundColor: "{colors.glass-light}"
    typography: "{typography.tab-label}"
    rounded: "{rounded.full}"
    height: "64px"
  tab-pill-paper-selected:
    backgroundColor: "{colors.mist}"
    textColor: "{colors.accent}"
  tab-folded:
    rounded: "{rounded.full}"
    size: "52px"
  mini-player-accessory:
    rounded: "{rounded.full}"
    height: "56px"
    padding: "0 6px 0 8px"
  mini-player-folded:
    rounded: "{rounded.full}"
    height: "52px"
---

# Design System: ListenJar app

This is a layer, not a second system. The brand core in the [root DESIGN.md](../../DESIGN.md) holds for the app: its colours, the one periwinkle accent, the platform's own face set heavy and tight, the corners, the shadow, glass and motion vocabularies, the Two-Tone and Opaque Fade rules, and the menus. This file adds what only a listening app needs and wins where the two differ. Tokens above that mirror the core are marked; the core is their source.

## Overview

**Creative North Star: "The Record Sleeve, Folding Into Glass"**

At rest, a show is its sleeve: the artwork runs full-bleed to the top of the screen, under the status bar, and the ink below is lit by a glow in the artwork's own colour, so every show's page looks like that show and no other. The only chrome on a sleeve at rest is a few small glass controls floating over the picture: back, share, more. Then the listener scrolls, and the sleeve folds away: the artwork slides up under a glass title bar that grows out of those same controls, and the tab bar folds around the mini player. Scroll back to the top and it all unfolds in reverse, exactly.

The two states are one design driven by the listener's finger. The artwork owns the page while the listener is looking; the glass takes over while they are reading, scrolling or choosing. What drives a morph is the finger's motion (which way it moves, how far, how fast), not where the page happens to be and not a timer. Push the content up and the chrome folds as far as the finger has pushed; pull it back and it unfolds; let go and it settles with the finger's own speed into the state the motion was heading for.

The app keeps the core's split of ink and paper, and adds the sleeve. Sleeve pages (a show, an episode, Now Playing) are the core's ink, lit by their artwork's glow. Paper pages (Home, Library, Search, Up Next, Downloads, Settings) stay on the core's working surfaces, the dashboard's paper side. The tab bar and the controls carry glass over both, and switch tone with the page under them.

**Key Characteristics:**
- Full-bleed artwork at the top of every show and episode page, under the status bar, fading into ink lit by a glow in the artwork's colour.
- Clear-glass controls over the artwork at rest; a dark-glass title bar once the hero has scrolled away.
- A floating glass tab pill with the mini player above it; on scrolling down they fold into two circles with the mini player between them.
- Morphs follow the finger's motion: they move with it while it's down and settle with its speed when it lets go.
- Things that exist in two places move between them: the artwork flies from a list into the hero, the mini player grows into Now Playing.

### Named Rules
**The Finger Rule.** A morph is driven by the finger's motion, never by the scroll position or a clock. While the finger is down, the morph moves by the distance the finger moves, in its direction, and reverses the moment the finger does. When the finger lets go, the morph settles with a spring that starts at the finger's release speed, toward the state that speed points to (or the nearer state, if the finger stopped). Momentum scrolling after a flick counts as the finger still moving. Timed curves are only for what no finger drives: a tap that opens something, the play-pause icon, a glass changing tone.
- The same on all five platforms: one design drawn by Flutter, under each OS's own back gesture, safe areas and media controls.

## Colors

The core's palette, plus one light per show, sampled from its artwork.

### Primary
- **Periwinkle** (accent): unchanged from the core. The play pill and every other action, on sleeves as on paper; the artwork's colour never replaces it.
- **Light Periwinkle** (accent-light): the accent on sleeves: links in show notes, the show link's chevron, selected tab on ink glass, the icons in secondary circle buttons.

### Neutral
- **Ink** (ink): the ground of every sleeve page, as on the core's ink panels. Never tinted: darkening an artwork's colour into a page ground turns most covers to mud.
- **Glow** (sampled per show): the artwork's most vivid hue, as light on the ink. Read the artwork at 20×20, sort its pixels into twelve 30° hue buckets, weight each by its saturation away from black and white, and take the heaviest bucket's average; lift it to saturation 0.55–0.85 and lightness 0.50–0.62, and shine it at 32% in a wide radial glow from behind the artwork, with the core's faint violet across from it. A greyscale cover glows periwinkle; a lettered cover glows its violet. Sample once, after the artwork decodes, so a second visit opens lit at once; the glow fades in from its own colour at alpha 0.
- **Sleeve fallback** (ink): the sleeve while there's no artwork or before the first sample. When the sample arrives, the ground fades from ink to the sleeve over the core's tone speed (300ms).
- **Glass** (glass-clear, glass-dark, glass-light): the core's glass. Clear over artwork, dark over sleeves and ink, light over paper.
- Text on sleeves is snow, snow-soft and accent-light, as on the core's ink. No other colours are needed.

### Named Rules
**The Artwork Is Light Rule.** A show's colour is only ever light on ink: its glow. It never fills a ground, a panel, a button, a chip, a progress bar or text: actions stay periwinkle on every sleeve, so the app looks like one app across a thousand shows.

**The Sampled-Not-Picked Rule.** Every glow comes from the same sampling and lifting, never a per-show choice or a fixed list. If a glow looks wrong, fix the rule.

## Typography

The core's face and voice: the platform's own UI face, headings at 700 tracked -0.03em. The app's sizes follow the user's text-size setting (Dynamic Type on iOS, font scale on Android): every size below scales with `MediaQuery.textScaler`, and layouts give way (titles wrap, rows grow) instead of clipping.

### Hierarchy
- **Sleeve title** (700, 28px, 1.1, -0.03em; 40px at wide widths): the show's or episode's title under the hero. Wraps freely; never truncated.
- **Sleeve kicker** (600, 14px, 1.3): the line above the title, in snow-soft: a date and a label ("July 24 · Video"), or a show's author.
- **Bar title** (700, 17px, 1.2, -0.02em): the title in the glass title bar once the hero has gone; one line, truncated with an ellipsis.
- **Tab label** (600, 12px): under each tab icon in the unfolded pill. The folded pill has no labels.
- Everything else (rows, show notes, settings) keeps the core's body, label and panel-title sizes.

### Named Rules
**The Title Passes Through Rule.** The sleeve title and the bar title are the same words in two places. The bar title fades in only as the sleeve title passes under the bar, so the name is never on screen twice at full strength.

## Layout

Two widths, split at 760px (`wideWidth` in shell.dart).

**Phones and narrow windows (below 760px).** Edge to edge. The sleeve hero is a square as wide as the screen, capped at 70% of the screen's height (taller screens crop the square's centre), starting at the very top of the screen, behind the status bar. Floating controls sit inside the safe area: 16px from the sides, 6px below the top inset. Below the hero, content runs in a 16px gutter. The tab pill floats 16px from the sides and 8px above the bottom inset; the mini player accessory floats 8px above the pill. Pages pad their bottom by the height of everything floating there, so the last row can scroll clear of it.

**Wide windows (760px and up).** The sidebar floats as a glass panel over the page's left (see Sidebar), and there is no tab pill. Pages fill the window and run on under it, padding their content past its edge, so a sleeve's ink and glow carry on behind the glass. The sleeve becomes a header in the content column: the artwork as a square with 18px corners on the left (240px with room, down to 160px, so the title and actions never wrap first), with a long dark shadow, kicker, title and actions to its right, top-aligned with it. No box and no blurred copy behind it: the glow is the only backdrop. The floating controls sit over ink here, so their glass is a white lift (12%) instead of a dark tint. The glass title bar and its scroll behaviour are the same, from the sidebar's edge across the top of the page. The mini player is the core's ink bar, floating at the bottom of the column over the page, which pads its end by the bar's height so the last row scrolls clear.

**Shelves and rows.** Artwork is the main image wherever a show appears: 160px squares with 18px corners in horizontal shelves (Home, search results for shows), 56px with 12px corners in episode and show rows. Nothing that shows a podcast is drawn without its artwork.

**Spacing.** Floating controls are 44px; the space between floating things is 8px; the sleeve's content starts 20px below the hero; sections on a sleeve are 32px apart, as on paper.

## Elevation & Depth

The app has three depths, from the bottom: the page (paper, or a sleeve with its artwork), the glass floating on it, and sheets and menus over both. Glass is the core's three kinds; only the floating controls, the title bar, the tab pill and the mini player accessory use it. Sheets and menus keep the core's solid surfaces and shadows.

### Named Rules
**The One Layer of Glass Rule.** Glass never sits on glass. When the back button and the action cluster become part of the title bar, they lose their own clear glass and the bar's glass carries them. When the mini player folds into the tab pill, they share one glass row, not two stacked.

**The Blur Is For Chrome Rule.** Only floating chrome blurs what's behind it. List rows, cards and sheets are solid. Keep the blur passes few: the pieces of one cluster (the folded tab circles and the mini player) share one blur pass (`BackdropGroup`), and nothing blurs while it is invisible.

## Shapes

The core's corners, plus the shapes glass takes. Every glass control is a full circle (one icon) or a full pill (several icons, or the mini player). The title bar is the one square-cornered piece of glass: it spans the screen edge to edge. Artwork is square, with corners by size (12px in rows, 18px in shelves and wide headers, none in the full-bleed hero). The hero's lower edge isn't a line: its bottom 25% fades into the ink.

## Components

### Floating controls (glass)
Small, round and out of the picture's way.
- **Back:** a 44px clear-glass circle at the top-left, a chevron in snow. On pages that open from a root it isn't there; the edge-swipe back gesture (iOS) and predictive back (Android) keep working alongside it.
- **Action cluster:** one 44px clear-glass pill at the top-right holding up to two icons (share, more). Further actions go in the more menu.
- **Over light artwork:** if the artwork's top 20% has an average luminance over 0.6, these controls use dark glass instead of clear, so the icons keep 3:1.
- **Press:** the core's press, plus the glass brightening one step (ink-tile over it) for 150ms.

### Sleeve hero (signature)
The page's opening at rest. The full-bleed artwork, its lower 25% fading into ink lit by its glow, the floating controls over it. Below, in order: the kicker, the sleeve title, the show link (for an episode: the show's 32px artwork, its name in snow-soft and a light-periwinkle chevron), then the action row.
- **Show page actions:** the play pill playing the newest unplayed episode, then sleeve circles for follow or unfollow, download and the episode filter.
- **Episode page actions:** the play pill for this episode, then sleeve circles for add to Up Next and download.
- **The status bar** turns light over a sleeve and dark over paper.

### Glass title bar (morph)
Grows out of the floating controls as the finger pushes the sleeve away (the Finger Rule):
- **Folding in:** once the sleeve title has reached the floating controls, every pixel the finger moves the content up carries the fold forward, completing over 48px of travel: the bar's dark glass fades in from glass-dark at alpha 0 (the Opaque Fade Rule), the back button and cluster drop their own glass, the bar title fades in, and at the end an ink-line hairline appears along the bar's bottom edge.
- **Folding out:** the finger pulling the content back down reverses it at the same rate. Back at the top of the page, the bar is always gone and the sleeve is whole.
- **Letting go mid-fold:** it settles with the finger's release speed, to folded if the finger was pushing up, to unfolded if pulling down.
- **The one limit:** while content sits under the controls, the bar can't fold away completely; it rests at its glass, so the controls stay readable over text.
- Height: the top inset plus 52px. The bar title is centred between the back button and the cluster.

### Play pill
The one primary action on a sleeve: periwinkle, 48px tall, a full pill, the core's accent shadow. Its label tells you what pressing it does:
- **Unplayed:** a play icon and the length ("1h", "42m").
- **Started:** a play icon and the time left ("23m left"), with the played part washed in accent-hover from the left.
- **Playing:** a pause icon, and the same label. The icon morphs between play and pause (`AnimatedIcons.play_pause`, 150ms).
- **Played:** a check and "Played"; pressing plays it again.
- The pill's width follows its label (200ms, ease-out-expo).

### Sleeve circles
Secondary actions on a sleeve: 48px circles of ink-tile with a light-periwinkle icon, hovering one step brighter. Every one has a tooltip and a screen-reader label.

### Tab pill and mini player (morph)
The phone's navigation: Home, Library, Search, Up Next, as today.
- **Unfolded (at rest):** a 64px glass pill, icons over 12px labels. The selected tab sits on an inner pill: ink-tile with light-periwinkle icon and label on dark glass, mist with periwinkle on light glass. When something has played, the mini player rides 8px above the pill as a 56px glass accessory: artwork, title and show, play or pause, skip forward.
- **Folded:** as the finger pushes the content up, the pill folds by the distance it travels, completing over 56px: the selected tab shrinks to a 52px circle at the left, Search to a 52px circle at the right, the other tabs and all labels fade out, and the mini player drops into the space between them as a 52px pill with its artwork, one line of title and play or pause. With nothing playing, only the two circles remain.
- **Unfolding:** the finger pulling the content back down unfolds it at the same rate, anywhere on the page, not only at the top. It doesn't matter how far down the page is: a short pull shows the tabs again.
- **Letting go and flicks:** on release it settles with the finger's speed toward the way it was moving; a flick folds or unfolds it in one go, and momentum scrolling carries on driving it. A finger that stops mid-fold leaves it to settle to the nearer state.
- **Taps:** tapping the folded tab circle, or changing pages, unfolds it on a timed 360ms ease-out-expo, the one timed path, since no finger is moving.
- **Tone:** dark glass over sleeves and Now Playing, light glass over paper, swapping at the core's tone speed.
- Tapping the mini player in either state opens Now Playing.

### Mini player to Now Playing (morph)
The mini player becomes Now Playing, not a sheet that covers it. On opening, the accessory's pill grows into the full screen (its corners easing from full to the sheet's 22px, then to the screen's own), its artwork flies to Now Playing's cover, and its title and buttons crossfade into Now Playing's. 420ms, ease-out-expo. Dragging Now Playing down follows the finger and shrinks it back toward the mini player; let go past halfway or on a flick (400px/s, as today) and it lands there, otherwise it springs back open.

### Artwork flight (morph)
When a show or episode opens from a list or a shelf, its artwork flies from there into the sleeve hero, its corners easing to none, while the page arrives under it; going back flies it home. 420ms, ease-out-expo, and on an edge-swipe back it follows the finger (`Hero` with `transitionOnUserGestures`). Every section's navigator gets its own hero controller for this; the shell currently turns heroes off.

### Sidebar (glass)
Wide windows only. A glass panel 216px wide, inset 10px from the window's top, left and bottom edges, with 18px corners and a hairline; it floats over the page rather than standing beside it, so there is no seam between two grounds.
- **Tone follows the page.** Light glass (white at 72%, the paper hairline, a faint shadow) over paper; dark glass (ink at 45%, the ink hairline, a deeper shadow) over a sleeve, so its glow shows through. Pages say which they are while in front (`Shown` in shell.dart); the panel crossfades over 300ms (instantly with reduced motion).
- **Top.** On macOS the window buttons sit in the panel's top, which is also the window's handle; elsewhere a 20px mark. No large logo.
- **Rows.** 34px rows with 10px corners: an 18px icon (or the show's artwork at 22px with 5px corners) and a 13.5px label in the primary colour, weight 500. The row in front gets a soft held pill (ink at 7% on paper, white at 12% on ink), weight 600 and a periwinkle icon; hover is half that pill. No white tile, no shadow. Counts (Up Next, Downloads) are plain tabular numbers in the faint colour, never a chip.
- **Following.** Under the sections, a quiet "Following" label and every followed show by its artwork. A row opens its show the way a section opens: in place of the page in front, on no stack, so there's no Back and no section stays lit. A show opened from inside a section (Library's grid, search) is that section's page: it takes the pill, and its section keeps only its periwinkle icon, so one row is ever held.
- **Rows replace, never stack.** Picking a sidebar row swaps the middle of the window; it never pushes a page. Picking the row already in front goes back to its first page.
- **Settings** is the panel's last row.

### Paper pages
Home, Library, Search, Up Next, Downloads and Settings keep the core's paper surfaces, panels and rows, with two changes: artwork leads wherever a show appears (shelves of 160px squares; 56px in rows), and a page's large title at the top folds into the light-glass title bar on scroll, the same way a sleeve does.

### Search
- **Source switch:** Podcasts and YouTube as one 44px segmented pill under the field: a paper-deep track, the chosen source on a white thumb that slides between them (300ms, ease-out-expo; instant with reduced motion). The chosen source's icon is periwinkle, its label the primary colour; the other is soft. YouTube is drawn as the app's own mark (`YouTubeMark`: a rounded screen with the play triangle cut out), in periwinkle or soft, never YouTube's red.
- **Video rows:** the frame leads, 16:9 with 12px corners: 160px wide, 120px where the row is under 480px. Its length sits on it as a small ink tag (white, tabular figures, 6px corners) at the bottom right; a playlist's tag carries its size, a playing video's turns periwinkle and says Playing. A started video's progress runs along the frame's foot in periwinkle. Below 480px the row itself plays and only the add menu stays beside it, so titles keep two lines.
- **Loading** shows rows of the shape that's coming: squares for shows, frames for videos.

## Do's and Don'ts

### Do:
- **Do** open every show and episode page on its artwork, full-bleed on a phone, fading into ink lit by its glow.
- **Do** drive every fold by the finger's motion: move with its travel while it's down, settle with its release speed when it lets go, and reverse the instant it does.
- **Do** move one object between places (artwork into the hero, the mini player into Now Playing) instead of crossfading two copies.
- **Do** keep periwinkle as the only action colour on every sleeve; the artwork's colour is ground only.
- **Do** keep the OS's own back gesture, safe areas, status bar style and the user's text size working on every page.
- **Do** keep every glass control at least 44px, with a screen-reader label and a tooltip.
- **Do** turn flights into a 150ms crossfade when the system's reduce-motion setting is on, and let folds settle without overshoot; folds still follow the finger, since the listener is moving them.

### Don't:
- **Don't** stand the sidebar beside the page as a slab of its own ground, or mark its selection with a white tile and shadow: it floats over the page as glass, and selection is a held pill.
- **Don't** put glass on glass, or blur anything that isn't floating chrome.
- **Don't** tint the ground, panels, buttons, chips, progress or text with a show's colour; it's light, not paint.
- **Don't** put a box, a frosted panel or a blurred copy of the artwork behind the header; the glow is the backdrop.
- **Don't** show a podcast without its artwork, or draw a sleeve hero smaller than the screen's width on a phone.
- **Don't** put the title in two places at full strength: the bar title waits until the sleeve title is passing under it.
- **Don't** fold chrome by where the page is or on a timer; a fold that fires after crossing a threshold, then plays by itself, is the thing to avoid.
- **Don't** make the app look different per OS: one design everywhere, with each OS's conventions (gestures, menus, media controls) underneath.
