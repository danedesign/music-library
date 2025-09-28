# Music Library

A single-page, iTunes-inspired library front-end that lists 2,472 tracks pulled from my playlist exports. The site lets you sort by song, artist, or album; filter instantly; and jump out to the matching YouTube Music search results. Album art is fetched lazily and cached client-side so the grid stays quick even on mobile.

## What's Inside

- `index.html`, `styles.css`, `app.js` – Static web app. Open `index.html` directly or serve the repo root to try it on other devices.
- `data/aggregated_playlist_youtube.csv` / `.json` – Deduplicated dataset with title, artist, album, YouTube Music link, and optional cached artwork URL.
- `data/*.ps1` – PowerShell helpers for aggregating playlists, filling album metadata, and caching artwork.

## Running the Site Locally

1. Serve the repository root (for example, `npx serve .` or `python -m http.server`).
2. Visit the served URL. Sorting, searching, and lazy artwork loading work offline because all data lives in `data/aggregated_playlist_youtube.json`.
3. On phones/tablets, the layout collapses into mobile cards; on desktop it stays table-based with sticky headers.

## Regenerating the Dataset

If you add new playlists:

```powershell
pwsh -NoLogo -File data/generate_playlist_csv.ps1
pwsh -NoLogo -File data/fill_album_info.ps1
pwsh -NoLogo -File data/fetch_album_art_deezer.ps1 -MaxRequests 600
```

Re-open the site to see the updates.

## Deployment Notes

The project is static, so you can host it from GitHub Pages, Netlify, Cloudflare Pages, etc. Ensure `data/aggregated_playlist_youtube.json` ships alongside the HTML so the fetch path `data/aggregated_playlist_youtube.json` resolves correctly.
