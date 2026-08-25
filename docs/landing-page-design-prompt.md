# Claude Design prompt — Onda landing page

Design a marketing landing page for **Onda**, an iOS podcast app. It will be published as a
static site on GitHub Pages, so design it as a single scrolling page (plus a mobile artboard).

## Visual language — match the app exactly

Onda is **neo-brutalist**: thick black borders, hard offset shadows (no blur), sharp 0px corners,
flat fills, no gradients, no glassmorphism.

- Borders: 2.5px solid, color = the text color (`#111111` light / `#FFFFFF` dark)
- Shadows: solid rectangle offset +4px x / +4px y in the border color — never a soft blur
- Corner radius: 0 everywhere
- Headers: system sans, weight 900 (black), UPPERCASE, letter-spacing -0.5px
- Body: system sans (SF Pro / -apple-system stack), regular/semibold
- Big display titles are single-line and shrink rather than wrap

### Palette (exact hex from the app)

Light:
- bg `#F2EFE4` (warm paper), elevated surface `#FFFFFF`
- text `#111111`, secondary `#4A4A44`, tertiary `#6B6A60`
- accent green `#1F6E4E`, accent wash `#1F6E4E` @ 13%
- border / shadow `#111111`

Dark:
- bg `#111111`, elevated surface `#1E2A24`
- text `#FFFFFF`, secondary `#C3C8C4`, tertiary `#8A8F8B`
- accent green `#3E8E68` (use `#2F7A57` behind small white text for AA contrast)
- border / shadow `#FFFFFF`

Design both light and dark versions. Small white text on an accent fill must clear 4.5:1.

## Sections

1. **Hero** — app name in huge black uppercase type, one-line positioning statement, and a
   bordered iPhone mockup showing the Now Playing screen. Onda is **not on the App Store yet**,
   so the hero carries a "COMING SOON TO THE APP STORE" badge (bordered pill, accent fill or
   accent wash, uppercase) instead of a download button. No email capture, no signup form, no
   waitlist — the badge is the only call to action, so give it enough weight to hold the hero.
2. **Feature grid** — bordered cards with hard shadows, one SF-Symbol-style icon each:
   - On-device transcripts — every episode searchable, transcription never leaves your phone
   - Natural-language search — "that episode where they talked about sourdough"
   - Clips — save a time range, export the audio or the text
   - Smart skips — skip silence, trim intros/outros, auto-skip ad chapters
   - Voice boost + per-show settings — speed, boost, downloads tuned per show
   - For You — on-device recommendations; nothing is sent to a server
3. **Privacy strip** — full-width accent-green band, white uppercase headline: no backend,
   no accounts, no tracking. Feeds come straight from the source.
4. **Screenshot row** — 3–4 bordered phone screens laid out with hard shadows and slight vertical
   offsets. Real captures live in `docs/landing/captures/` (see the README there for what each one
   shows); the strongest four are `01-library-grid.png`, `13-nl-transcript-search.png`,
   `07-transcript-follow.png`, and `21-clips-list-dark.png`.
5. **Footer** — small text links (GitHub, Privacy, Support), thick top rule.

## Deliverables

- Desktop artboard (1440px wide), light theme
- Desktop artboard, dark theme
- Mobile artboard (390px wide)

Keep the whole thing static-site friendly: system fonts only, no external assets beyond images,
and structure it so it maps cleanly onto a single `index.html` + `style.css`.
