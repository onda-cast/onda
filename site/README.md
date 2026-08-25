# Onda landing page

Static GitHub Pages site for Onda. Implements the three artboards in
`../docs/landing-page-design-prompt.md` / the Claude Design canvas: desktop light, desktop dark,
and mobile 390. One page adapts across all three — the light/dark split is driven by
`prefers-color-scheme`, not a toggle, so it follows the visitor's system setting the way the app
follows the system theme.

## Files

- `index.html` — the whole page; no build step, no framework, no external requests
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
- `Privacy` links to the on-page privacy band. There is a fuller policy on the
  `claude/app-store-privacy-policy-88f783` branch — point the link at that once it lands and is
  published.
