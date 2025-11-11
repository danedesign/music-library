const DATA_URL = "data/aggregated_playlist_youtube.json";

const tableContainer = document.querySelector(".table-container");
const tableBody = document.querySelector("#songs-body");
const table = document.querySelector("#songs-table");
const template = document.querySelector("#song-row-template");
const searchInput = document.querySelector("#search");
const countLabel = document.querySelector("#song-count");
const emptyState = document.querySelector("#empty-state");
const sortButtons = Array.from(document.querySelectorAll(".sort-btn"));
const themeToggle = document.querySelector("#theme-toggle");
const reduceMotionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
let prefersReducedMotion = reduceMotionQuery.matches;
if (reduceMotionQuery.addEventListener) {
  reduceMotionQuery.addEventListener('change', event => {
    prefersReducedMotion = event.matches;
  });
}
const alphaStrip = document.querySelector(".alpha-strip");
const alphaLetters = alphaStrip ? Array.from(alphaStrip.querySelectorAll('[data-letter]')) : [];
const navBar = document.querySelector(".nav-bar");
const searchBlock = document.querySelector(".search-block");
const toolbar = document.querySelector(".toolbar");
let letterTargets = new Map();

const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });

let allSongs = [];
let filteredSongs = [];
const sortState = { key: "Title", direction: "asc" };

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
  tableBody.innerHTML = "";

  if (!rows.length) {
    emptyState.hidden = false;
    table.setAttribute("aria-hidden", "true");
    countLabel.textContent = "0 songs";
    updateAlphaStrip();
    queueStackOffsetUpdate();
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

    const titleText = newRow.querySelector(".title-text");
    const subtitle = newRow.querySelector(".subtitle");
    if (titleText) titleText.textContent = song.Title || "Untitled";
    if (subtitle) subtitle.textContent = song.Album || "Single";
    if (artistCell) artistCell.textContent = song.Artist || "-";
    if (albumCell) albumCell.textContent = song.Album || "-";

    fragment.appendChild(newRow);
  }

  tableBody.appendChild(fragment);
  updateAlphaStrip();
  countLabel.textContent = `${rows.length.toLocaleString()} song${rows.length === 1 ? "" : "s"}`;
  queueStackOffsetUpdate();
}

function openSong(row) {
  const url = row.dataset.url;
  if (url) {
    window.open(url, "_blank", "noopener");
  }
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

function updateAlphaStrip() {
  if (!alphaStrip) {
    return;
  }
  letterTargets = new Map();
  const key = sortState.key.toLowerCase();
  const rows = Array.from(tableBody.children);
  for (const row of rows) {
    const value = row.dataset[key] || row.dataset.title || "";
    const letter = extractLetter(value);
    if (letter && !letterTargets.has(letter)) {
      letterTargets.set(letter, row);
    }
  }
  alphaLetters.forEach(span => {
    const letter = span.dataset.letter;
    if (letterTargets.has(letter)) {
      span.classList.remove("disabled");
    } else {
      span.classList.add("disabled");
    }
  });
}

function extractLetter(value) {
  if (!value) {
    return '#';
  }
  const first = value.trim().charAt(0).toUpperCase();
  if (first >= 'A' && first <= 'Z') {
    return first;
  }
  return '#';
}

function highlightRow(row) {
  if (!row) {
    return;
  }
  row.classList.add("jump-highlight");
  setTimeout(() => row.classList.remove("jump-highlight"), 800);
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

let pendingSearchValue = '';
let searchFrame = null;
let resizeFrame = null;
searchInput.addEventListener("input", event => {
  pendingSearchValue = event.target.value;
  if (searchFrame) {
    return;
  }
  if (window.requestAnimationFrame) {
    searchFrame = window.requestAnimationFrame(() => {
      searchFrame = null;
      applySearch(pendingSearchValue);
    });
  } else {
    applySearch(pendingSearchValue);
  }
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

function locateRow(element) {
  return element.closest(".song-row");
}

tableBody.addEventListener("click", event => {
  const row = locateRow(event.target);
  if (row) {
    openSong(row);
  }
});

tableBody.addEventListener("keydown", event => {
  if (event.key !== "Enter" && event.key !== " ") {
    return;
  }
  const row = locateRow(event.target);
  if (row) {
    event.preventDefault();
    openSong(row);
  }
});

if (alphaLetters.length) {
  alphaLetters.forEach(span => {
    span.addEventListener("click", () => {
      if (span.classList.contains("disabled")) {
        return;
      }
      const target = letterTargets.get(span.dataset.letter);
      if (target) {
        const scrollBehavior = prefersReducedMotion ? 'auto' : 'smooth';
        target.scrollIntoView({ behavior: scrollBehavior, block: 'start' });
        highlightRow(target);
      }
    });
  });
}

const THEME_STORAGE_KEY = "music-library-theme";
const prefersDark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
const savedTheme = localStorage.getItem(THEME_STORAGE_KEY);
if (savedTheme === "dark" || (!savedTheme && prefersDark)) {
  document.body.classList.add("dark-mode");
}
updateThemeToggleLabel();

if (themeToggle) {
  themeToggle.addEventListener("click", () => {
    document.body.classList.toggle("dark-mode");
    const mode = document.body.classList.contains("dark-mode") ? "dark" : "light";
    localStorage.setItem(THEME_STORAGE_KEY, mode);
    updateThemeToggleLabel();
    queueStackOffsetUpdate();
  });
}

function updateThemeToggleLabel() {
  if (!themeToggle) {
    return;
  }
  const isDark = document.body.classList.contains("dark-mode");
  themeToggle.textContent = isDark ? "Light Mode" : "Dark Mode";
}

function scheduleDataLoad() {
  if ("requestIdleCallback" in window) {
    requestIdleCallback(loadSongs, { timeout: 2000 });
  } else if ("requestAnimationFrame" in window) {
    requestAnimationFrame(() => loadSongs());
  } else {
    setTimeout(loadSongs, 0);
  }
}

function updateStackOffset() {
  if (!navBar || !searchBlock || !toolbar) {
    return;
  }
  const navHeight = navBar.offsetHeight;
  const searchHeight = searchBlock.offsetHeight;
  const toolbarHeight = toolbar.offsetHeight;
  const docStyle = document.documentElement.style;
  docStyle.setProperty("--nav-height-px", `${navHeight}px`);
  docStyle.setProperty("--search-height-px", `${searchHeight}px`);
  docStyle.setProperty("--toolbar-height-px", `${toolbarHeight}px`);
  docStyle.setProperty("--stack-offset-px", `${navHeight + searchHeight + toolbarHeight}px`);
}

function queueStackOffsetUpdate() {
  if (resizeFrame) {
    return;
  }
  if (window.requestAnimationFrame) {
    resizeFrame = window.requestAnimationFrame(() => {
      resizeFrame = null;
      updateStackOffset();
    });
  } else {
    updateStackOffset();
  }
}

window.addEventListener("resize", queueStackOffsetUpdate, { passive: true });
window.addEventListener("orientationchange", queueStackOffsetUpdate);

scheduleDataLoad();
updateStackOffset();
