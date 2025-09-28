const DATA_URL = "data/aggregated_playlist_youtube.json";
const PLACEHOLDER_ART =
  "data:image/svg+xml,%3csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3e%3crect width='120' height='120' rx='14' ry='14' fill='%232f323a'/%3e%3cpath d='M22 90V30a8 8 0 0 1 8-8h60a8 8 0 0 1 8 8v60a8 8 0 0 1-8 8H30a8 8 0 0 1-8-8Zm22-42v30l28-15-28-15Z' fill='%239aa0ad' opacity='0.55'/%3e%3c/svg%3e";

const tableContainer = document.querySelector(".table-container");
const tableBody = document.querySelector("#songs-body");
const table = document.querySelector("#songs-table");
const template = document.querySelector("#song-row-template");
const searchInput = document.querySelector("#search");
const countLabel = document.querySelector("#song-count");
const emptyState = document.querySelector("#empty-state");
const sortButtons = Array.from(document.querySelectorAll(".sort-btn"));

const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });

let allSongs = [];
let filteredSongs = [];
const sortState = { key: "Title", direction: "asc" };

const coverCache = new Map();
const inFlightCover = new Map();

const observer = new IntersectionObserver(
  entries => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        observer.unobserve(entry.target);
        requestArtwork(entry.target);
      }
    }
  },
  { root: tableContainer, threshold: 0.1 }
);

async function loadSongs() {
  try {
    const response = await fetch(DATA_URL);
    if (!response.ok) {
      throw new Error(`Failed to load data (${response.status})`);
    }
    const data = await response.json();
    allSongs = Array.isArray(data) ? data : [];
    filteredSongs = [...allSongs];
    sortAndRender(false);
  } catch (error) {
    console.error("Unable to load songs", error);
    countLabel.textContent = "Unable to load songs";
  }
}

function renderRows(rows) {
  observer.disconnect();
  tableBody.innerHTML = "";

  if (!rows.length) {
    emptyState.hidden = false;
    table.setAttribute("aria-hidden", "true");
    countLabel.textContent = "0 songs";
    return;
  }

  emptyState.hidden = true;
  table.removeAttribute("aria-hidden");

  const fragment = document.createDocumentFragment();

  for (const song of rows) {
    const newRow = template.content.firstElementChild.cloneNode(true);
    newRow.dataset.url = song.YouTubeMusicUrl;
    newRow.dataset.artist = song.Artist;
    newRow.dataset.title = song.Title;
    newRow.dataset.album = song.Album || "";

    const titleCell = newRow.querySelector(".title-cell");
    const artistCell = newRow.querySelector(".artist-cell");
    const albumCell = newRow.querySelector(".album-cell");

    if (artistCell) artistCell.dataset.label = "Artist";
    if (albumCell) albumCell.dataset.label = "Album";

    const coverImg = newRow.querySelector(".album-cover");
    if (coverImg) {
      coverImg.src = PLACEHOLDER_ART;
      const displayTitle = song.Title || "Unknown title";
      const displayArtist = song.Artist || "Unknown artist";
      coverImg.alt = `${displayTitle} — ${displayArtist} cover art`;
      coverImg.dataset.coverKey = buildCoverKey(song);
      coverImg.dataset.artist = song.Artist;
      coverImg.dataset.album = song.Album || "";
      coverImg.dataset.title = song.Title;
      observer.observe(coverImg);
    }

    const titleText = newRow.querySelector(".title-text");
    const subtitle = newRow.querySelector(".subtitle");
    if (titleText) titleText.textContent = song.Title || "Untitled";
    if (subtitle) subtitle.textContent = song.Album || "Single";
    if (artistCell) artistCell.textContent = song.Artist || "—";
    if (albumCell) albumCell.textContent = song.Album || "—";

    newRow.addEventListener("click", () => openSong(newRow));
    newRow.addEventListener("keydown", event => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        openSong(newRow);
      }
    });

    fragment.appendChild(newRow);
  }

  tableBody.appendChild(fragment);
  countLabel.textContent = `${rows.length.toLocaleString()} song${rows.length === 1 ? "" : "s"}`;
}

function openSong(row) {
  const url = row.dataset.url;
  if (url) {
    window.open(url, "_blank", "noopener");
  }
}

function buildCoverKey(song) {
  if (song.Album) {
    return `${song.Artist.toLowerCase()}|${song.Album.toLowerCase()}`;
  }
  return `${song.Artist.toLowerCase()}|${song.Title.toLowerCase()}`;
}

function requestArtwork(img) {
  const key = img.dataset.coverKey;
  if (!key) {
    return;
  }

  if (coverCache.has(key)) {
    img.src = coverCache.get(key);
    return;
  }

  if (inFlightCover.has(key)) {
    inFlightCover.get(key).then(url => {
      img.src = url;
    });
    return;
  }

  const lookupPromise = fetchArtwork({
    artist: img.dataset.artist,
    album: img.dataset.album,
    title: img.dataset.title,
  })
    .then(url => {
      const finalUrl = url || PLACEHOLDER_ART;
      coverCache.set(key, finalUrl);
      img.src = finalUrl;
      return finalUrl;
    })
    .catch(() => {
      coverCache.set(key, PLACEHOLDER_ART);
      img.src = PLACEHOLDER_ART;
      return PLACEHOLDER_ART;
    })
    .finally(() => {
      inFlightCover.delete(key);
    });

  inFlightCover.set(key, lookupPromise);
}

async function fetchArtwork({ artist, album, title }) {
  const base = "https://itunes.apple.com/search";
  const query = album ? `${artist} ${album}` : `${artist} ${title}`;
  const url = `${base}?term=${encodeURIComponent(query)}&entity=album&limit=1`;
  try {
    const response = await fetch(url);
    if (!response.ok) {
      return null;
    }
    const payload = await response.json();
    if (payload.resultCount > 0) {
      const artwork = payload.results[0].artworkUrl100;
      if (artwork) {
        return artwork.replace("100x100bb", "300x300bb");
      }
    }
  } catch (error) {
    console.debug("Artwork fetch failed", error);
  }
  return null;
}

function applySearch(term) {
  const query = term.trim().toLowerCase();
  if (!query) {
    filteredSongs = [...allSongs];
  } else {
    filteredSongs = allSongs.filter(song => {
      return [song.Title, song.Artist, song.Album]
        .filter(Boolean)
        .some(value => value.toLowerCase().includes(query));
    });
  }
  sortAndRender(false);
}

function sortAndRender(toggleDirection = true, keyOverride) {
  const key = keyOverride || sortState.key;
  if (key !== sortState.key) {
    sortState.key = key;
    sortState.direction = "asc";
  } else if (toggleDirection) {
    sortState.direction = sortState.direction === "asc" ? "desc" : "asc";
  }

  const direction = sortState.direction === "asc" ? 1 : -1;
  filteredSongs.sort((a, b) => {
    const left = a[key] || "";
    const right = b[key] || "";
    const comparison = collator.compare(left, right);
    return comparison * direction;
  });

  updateSortIndicators();
  renderRows(filteredSongs);
}

function updateSortIndicators() {
  for (const button of sortButtons) {
    if (button.dataset.sort === sortState.key) {
      button.classList.add("active");
      button.dataset.direction = sortState.direction === "asc" ? "▲" : "▼";
    } else {
      button.classList.remove("active");
      button.dataset.direction = "";
    }
  }

  const headers = table.querySelectorAll("th[data-sort]");
  headers.forEach(header => {
    header.classList.toggle("active", header.dataset.sort === sortState.key);
  });
}

searchInput.addEventListener("input", event => {
  applySearch(event.target.value);
});

sortButtons.forEach(button => {
  button.addEventListener("click", () => {
    sortAndRender(true, button.dataset.sort);
  });
});

const headerSortTargets = table.querySelectorAll("th[data-sort]");
headerSortTargets.forEach(header => {
  header.addEventListener("click", () => {
    sortAndRender(true, header.dataset.sort);
  });
});

loadSongs();



