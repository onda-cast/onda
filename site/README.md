# Onda landing page

Static GitHub Pages site for Onda. Implements the three artboards in
`../docs/landing-page-design-prompt.md` / the Claude Design canvas: desktop light, desktop dark,
and mobile 390. One page adapts across all three.

## Theming

Three states, matching how the app's own Appearance setting works: follow the system, force
light, force dark. The header toggle sets `data-theme` on `<html>` and persists the choice in
`localStorage`; with nothing stored the page follows `prefers-color-scheme`.

Dark tokens are therefore declared twice in `style.css` — once inside
`@media (prefers-color-scheme: dark)` guarded by `:root:not([data-theme="light"])`, and once
under `:root[data-theme="dark"]`. The guard is what lets an explicit *light* choice win on a
system set to dark; without it, source order alone would lose that case.

An inline script in `<head>` applies the stored choice before first paint so the other palette
never flashes. Screenshots are plain `<img>` with `data-light`/`data-dark` rather than
`<picture>`, because `<source media="(prefers-color-scheme: dark)">` only ever follows the OS —
it would have flipped the page but not the images. Without JS the page still renders and follows
the system theme; only the image swap and the toggle need it.

## Files

- `index.html` — the landing page; no build step, no framework, no external requests
- `privacy/index.html` — the privacy policy, served at `/privacy/`. This is the URL App Store
  Connect requires in the app's listing, so it has to stay publicly reachable without a login.
  It is the canonical copy of the policy — `docs/PRIVACY.md` on the
  `claude/app-store-privacy-policy-88f783` branch is the same text in Markdown, and the two will
  drift if both are kept
- `style.css` — palette tokens copied verbatim from `Onda/Theme/Palette.swift`
- `assets/img/*.jpg` — real app screenshots (light + dark pairs), 620px wide (840 for the hero)
- `assets/video/*.mp4` — screen recordings, H.264, silent, click-to-play (`preload="none"`)
- `.nojekyll` — serve files as-is

Originals for every asset live in `../docs/landing/captures/` with a README explaining each one.
Regenerate the web-sized copies with `sips` (see git history for the exact invocations) and the
videos with `avconvert --preset Preset640x480`.

## Deploying

`.github/workflows/pages.yml` publishes this directory on every push to `main` that touches
`site/`. To turn it on once: **Settings → Pages → Build and deployment → Source: GitHub Actions**.
Nothing outside `site/` is published, so the rest of `docs/` stays private to the repo.

Published URL once Pages is on: **https://onda-cast.github.io/onda/**

## Before it goes live

- The repo is currently **private**. GitHub Pages on a private repo needs GitHub Team or
  Enterprise Cloud; on the Free plan the repo has to be public for the site to build and serve.
- Footer `GitHub` → the repo, `Support` → its issues. Both 404 for logged-out visitors while the
  repo is private.
- The footer `Privacy` link and the privacy band's button both point at `/privacy/`. Use
  **https://onda-cast.github.io/onda/privacy/** as the Privacy Policy URL in App Store Connect.
- **The policy's Contact section is interim.** It points at GitHub issues rather than an email
  address, to keep a personal address off a public page. Apple expects a contact route on the
  policy, so swap in the real contact alias (in `site/privacy/index.html`, marked with a TODO)
  before submitting to the App Store.
