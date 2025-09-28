# Music Library

A single-page, iTunes-inspired library front-end that lists 2,472 tracks pulled from my playlist exports. The site lets you sort by song, artist, or album; filter instantly; and jump out to the matching YouTube Music search results. Album art is fetched lazily and cached client-side so the grid stays quick even on mobile.

## What's Inside

- `site/` – Static web app (HTML/CSS/JS). Open `site/index.html` in a browser or serve the folder to try it on other devices.
- `aggregated_playlist_youtube.csv` / `.json` – Deduplicated dataset with title, artist, album, YouTube Music link, and optional cached artwork URL.
- PowerShell helpers:
  - `generate_playlist_csv.ps1` – Aggregate playlist exports into the master CSV/JSON.
  - `fill_album_info.ps1` plus refinement scripts – Backfill album names from local libraries, MusicBrainz, and Deezer.
  - `fetch_album_art*.ps1` – Cache album art URLs before shipping the JSON to the site.

## Running the Site Locally

1. From the repo root, serve the `site` directory (for example, `npx serve site` or `python -m http.server --directory site`).
2. Visit the served URL. Sorting, searching, and lazy artwork loading work offline because all data lives in `aggregated_playlist_youtube.json`.
3. On phones/tablets, the layout collapses into mobile cards; on desktop it stays table-based with sticky headers.

## Regenerating the Dataset

If you add new playlists:

```powershell
pwsh -NoLogo -File generate_playlist_csv.ps1
pwsh -NoLogo -File fill_album_info.ps1
pwsh -NoLogo -File fetch_album_art_deezer.ps1 -MaxRequests 600
```

Re-open the site to see the updates.

## Deployment Notes

The project is static, so you can push `site/` to any static host (GitHub Pages, Netlify, Cloudflare Pages, etc.). Make sure `aggregated_playlist_youtube.json` stays adjacent to the HTML so the fetch path `../aggregated_playlist_youtube.json` resolves correctly.
