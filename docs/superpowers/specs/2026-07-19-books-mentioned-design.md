# Books Mentioned — Best-Effort Extraction Design (2026-07-19)

**Goal.** Answer one specific question a listener actually has: *"what was that book in THIS
episode?"* The interface is strictly per-episode and user-initiated — a listener asks for the
books of one episode from that episode's detail screen, and the funnel runs over that episode's
notes and transcript only. There is deliberately **no open-ended mode**: no cross-episode book
browsing, no "scan my library", no bulk or background extraction. Best-effort by design:
**precision over recall** — a book only appears if it verifies against a real-world book
catalog; fuzzy or unverifiable mentions are silently dropped. One hallucinated book costs more
trust than five misses.

This extends the app's knowledge-capture identity (transcripts, clips, search): the episode
becomes a bibliography, and every entry is a jump-back-into-context affordance — no big podcast
app has this.

## The funnel: candidates → verification

Four candidate tiers, cheapest and most precise first, all feeding one verification gate.

**Tier 1 — Show-notes links (highest precision, no ML).** Amazon (`/dp/<ASIN>`, `/gp/product/`),
Bookshop.org, and Goodreads URLs in the episode description identify books near-perfectly:
extract title/ISBN from the URL slug or resolve the ASIN/ISBN via the verification API.
*Prerequisite:* `RSSFeedParser` strips HTML from `notes` at parse time (`stripHTML`,
RSSFeedParser.swift:133), destroying `href`s. The parser must additionally collect `href`
URLs from the raw description into a new `ParsedEpisode.noteLinks: [URL]` before stripping —
`Episode` gains a matching stored array. Notes stay plain text everywhere else.

**Tier 2 — Text patterns (high precision, low recall).** Over notes *and* transcript cues:
- `"<Title>" by <Name>` / `<Title> by <Name>` where NLTagger tags `<Name>` as `.personalName`
  (reusing the SmartQuery NLTagger infrastructure and its simulator-flake guards).
- "Books mentioned" / "Reading list" blocks in notes: subsequent lines parsed as `Title — Author`.

**Tier 3 — On-device LLM extraction (the only tier that catches conversational mentions).**
Apple Foundation Models (same framework, gating, and protocol-behind-a-fake pattern as
`FoundationModelsChapterGenerator`): prompt over transcript text in chapter-sized chunks,
structured output of `{title, author?, nearbyQuote}`. The `nearbyQuote` is matched back to a cue
(FTS or substring scan) to recover the timestamp. Available only on Apple Intelligence hardware —
Tiers 1–2 are the floor everywhere else.

**Verification gate (what makes best-effort trustworthy).** Every candidate from every tier is
checked against **OpenLibrary** (keyless `search.json?title=&author=`; Google Books as a
documented fallback if OpenLibrary reliability disappoints). A candidate survives only if a
result fuzzy-matches: normalized-title similarity ≥ 0.85 AND (author matches when the candidate
has one). The match's work key, canonical title/author, and cover URL become the stored record.
No match → dropped, never shown. The matcher is a pure function with fixture tests — thresholds
live in one place.

## Privacy

Verification sends candidate titles to a third-party API. Consistent with the taste-profile
rule, **private feeds (`Podcast.isPrivateFeed`) are excluded entirely** — no candidates are
generated from their notes or transcripts, and the Books section doesn't render for them. Public
shows' candidate titles are the only thing transmitted; never transcript text (the LLM tier runs
on-device, and `nearbyQuote` is used locally only).

## Data model

```
BookMention (@Model)
  episode: Episode?            (inverse: Episode.bookMentions, cascade from Episode)
  workKey: String              (OpenLibrary work key — dedupe key per episode)
  title: String                (canonical, from the catalog — not the raw candidate)
  author: String?
  coverURL: URL?
  sourceTier: String           ("link" | "notes" | "transcript")
  timestamp: TimeInterval?     (feed-seconds; transcript-derived mentions only)
  createdAt: Date
ParsedEpisode.noteLinks: [URL] (parser-level; persisted onto Episode.noteLinks)
```

Dedupe per episode by `workKey`, keeping the entry with a timestamp over one without.

## Service & triggering

`BookMentionService` (`@MainActor @Observable`, dependencies behind protocols: the LLM
extractor, the verifier's transport, NLTagger wrapper — all injectable fakes for tests).

**On-demand, single-episode only, like transcription and auto-chapters:** a "Find books"
affordance in the episode detail's Books section runs the funnel once **for that episode** and
persists results; re-running replaces them. The service API takes exactly one `Episode` —
there is intentionally no batch entry point, no automatic background sweeps, and no
library-wide invocation, both to keep the cost model honest (network verification + LLM time
are spent only on an episode the user asked about) and to keep the product scope a per-episode
question-answering tool rather than an open-ended cataloguing system. `progress`/`lastFailure`
state mirrors `TranscriptService`'s shape.

## UX

- **EpisodeDetailView** gains a "Books Mentioned" section: rows of cover thumbnail (ArtworkView
  fallback seeded by title), canonical title, author, and a source badge only for
  transcript-derived rows (a small timestamp chip).
- Tapping a row with a timestamp = the existing transcript-jump flow (seek + open player, "Back
  to transcript" affordance). Rows without timestamps open THIS episode's transcript with the
  in-panel search prefilled with the title — never the library-wide transcript search; the
  feature's whole frame is this one episode.
- Long-press: copy title/author; "Search OpenLibrary" link out (external, user-initiated).
- Empty/degraded states use `BrutalEmptyState`: never ran → "Find books" CTA with one line of
  explanation; ran, none verified → "No books found — mentions that can't be verified aren't
  shown"; offline → "Needs a connection to verify books" (candidates without verification are
  never persisted, so offline simply pauses the feature).
- All styling per the theme system: `scaledFont`, `accentStrong` for any white-on-accent CTA,
  44pt targets, checkmark/selected conventions.

## Degradation ladder (explicitly accepted)

| Environment | Behavior |
| --- | --- |
| Apple Intelligence + network | Full funnel: links + patterns + LLM, all verified |
| No Apple Intelligence | Tiers 1–2 only — notes links and explicit patterns |
| No network | Feature paused (verification is mandatory); persisted books still shown |
| Private feed | Feature absent |
| ASR-garbled titles | Lost recall, by design — verification rejects them |

## Testing

- Pure units with fixtures: link parser (Amazon/Bookshop/Goodreads URL shapes), pattern
  extractor (quoted-title, "by Person", reading-list blocks), fuzzy matcher (threshold table:
  exact, subtitle-dropped, ASR-garbled negative cases), per-episode dedupe.
- Service tests with stubbed extractor/verifier: funnel ordering, private-feed exclusion,
  offline no-persist, replace-on-rerun.
- Parser change (`noteLinks`) covered in `RSSFeedParserTests` with an HTML-notes fixture.
- LLM tier untestable in CI (hardware-gated) — protocol fake asserts prompt/chunking contract,
  same accepted gap as `FoundationModelsChapterGenerator`.

## Out of scope (v1)

- Any cross-episode or open-ended surface: a "Books" library screen, "scan all episodes",
  reading-list export. Explicitly a non-goal of this feature's interface — if ever revisited it
  is a separate product decision, not an extension of this one. The per-episode rows would
  support it, but nothing in v1 may invite it.
- Other media (films, albums, papers) — same funnel would work; separate spec.
- Affiliate/purchase integration; price or availability data.
- Automatic extraction on download/transcription (revisit with real usage data).
- Reranking the taste profile with book signals.

## Risks

- **OpenLibrary reliability/rate limits** — keyless and community-run; mitigate with a
  per-episode run (bursts of ≤ ~15 lookups), result caching on the persisted rows, and the
  documented Google Books fallback if it proves flaky.
- **LLM hallucination** — contained by the verification gate; a plausible-but-wrong title that
  ALSO exists as a real book (e.g. mishearing one bestseller as another) is the residual risk,
  accepted as best-effort.
- **Notes HTML variance** — messy feeds may defeat the link parser; Tier 2/3 still apply.
- **Foundation Models availability** — narrower device slice than iOS 26; the ladder above is
  the product answer, not a blocker.
