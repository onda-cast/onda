# Onda landing-page captures

Real screens from Onda running in the iOS Simulator (iPhone 17, iOS 26.3), subscribed to
**Odd Lots** (Bloomberg) and the **Works in Progress Podcast**. Every screenshot is a 3x retina
PNG at 1206x2622; recordings are H.264 .mp4, silent (simctl does not capture audio).

## Screenshots

| File | Screen | Use it for |
| --- | --- | --- |
| `01-library-grid.png` | Library grid, both shows, unplayed badges, mini-player | Hero shot |
| `02-show-detail-oddlots.png` | Odd Lots show page + episode list | Show page |
| `03-show-settings.png` | Per-show settings (Boost Med, Skip Silence On, Ad Skip Auto, 15s intro trim) | Per-show settings feature |
| `04-episode-detail.png` | Episode sheet with description | Episode detail |
| `05-episode-list-miniplayer.png` | Episode list, downloaded + in-progress states, mini-player | Downloads / playback |
| `06-now-playing.png` | Now Playing (light) | Hero / player |
| `07-transcript-follow.png` | Transcript auto-following playback, speaker labels | Transcripts feature |
| `08-transcript-search.png` | Find-in-transcript, 2/16 matches, hit highlighted | In-episode search |
| `09-clipping-active.png` | "Clipping · 0:05 / End Clip" banner over artwork | Clips feature |
| `10-clip-editor.png` | New Clip editor with auto-pulled transcript excerpt | Clips feature |
| `11-show-detail-wip.png` | Works in Progress show page | Second show |
| `12-show-search.png` | Per-show episode search ("rats") | Search |
| `13-nl-transcript-search.png` | Natural-language search: "oil refinery in Odd Lots" | **Marquee feature** |
| `14-smart-queue.png` | Cross-show UNPLAYED smart queue + PLAY ALL | Smart queues |
| `15-for-you.png` | On-device recommendations with reasons ("Matches your interest in investing, technology") | Privacy / For You |
| `16-profile-settings.png` | Global settings | Settings |
| `17-library-grid-dark.png` | Library grid, dark | Dark theme |
| `18-now-playing-dark.png` | Now Playing, dark | Dark theme |
| `19-transcript-dark.png` | Transcript, dark | Dark theme |
| `20-clip-editor-dark.png` | Clip editor with a note, dark | Dark theme |
| `21-clips-list-dark.png` | Clips list, two clips, dark | Clips feature |

## Recordings

| File | Flow |
| --- | --- |
| `rec-01-nl-search.mp4` | Typing "oil refinery in Odd Lots" into cross-transcript search, results resolving live |
| `rec-02-player-transcript.mp4` | Mini-player → Now Playing → transcript sheet → scrolling cues → close |
| `rec-03-clip-flow.mp4` | Scissors → clipping banner → extend → End Clip → editor → note → Save → Clips list |

Playback is paused in the recordings, so the scrubber does not advance — they show navigation and
UI, not audio playback.

The raw `.mp4` originals here are **gitignored** — 56 MB of intermediate media does not belong in
the repo. The web-sized copies the site actually serves are committed at `site/assets/video/`.
Re-record from the simulator if you need the originals again.
