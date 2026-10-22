// The photo analysis window (своя версия): pick a folder, run `digup analyze`, and see what the pictures and videos
// are about — groups of alike files a model named, with what they take up — then open a group to see its files.
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const ask = (request) => invoke("ask", { request });
const fileURL = (path) => tauri.core.convertFileSrc(path);
const $ = (id) => document.getElementById(id);

// Pictures the web view shows as they are; anything else (HEIC, video…) comes as a JPEG the helper renders.
const SHOWN_AS_IS = new Set(["jpg", "jpeg", "png", "gif", "webp", "bmp"]);
const STAGES = {
  reading: "Читаю, что программа уже знает о файлах…",
  grouping: "Собираю похожие файлы в группы…",
  downloading: "Скачиваю модель, которая придумывает названия (3,3 ГБ, один раз)…",
  loading: "Загружаю модель…",
  naming: "Модель смотрит на группы и придумывает названия…",
};

const state = { info: null, result: null, group: null, running: false };

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function plural(n, one, few, many) {
  const tens = n % 100, ones = n % 10;
  if (tens >= 11 && tens <= 14) return many;
  if (ones === 1) return one;
  if (ones >= 2 && ones <= 4) return few;
  return many;
}
const files = (n) => `${n.toLocaleString("ru-RU")} ${plural(n, "файл", "файла", "файлов")}`;

function size(bytes) {
  const units = ["Б", "КБ", "МБ", "ГБ", "ТБ"];
  let value = bytes, unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; }
  return `${value.toLocaleString("ru-RU", { maximumFractionDigits: value < 10 && unit > 0 ? 1 : 0 })} ${units[unit]}`;
}

const nameOf = (path) => path.split(/[\\/]/).filter(Boolean).pop() || path;

// MARK: Thumbnails

const renders = new Map();
/// A small JPEG from the helper (a photo straight from the camera is megabytes: a grid of them would crawl); the file
/// itself when the helper can't, and it's a picture the web view shows.
function picture(path, kind) {
  const extension = (path.split(".").pop() || "").toLowerCase();
  const key = `${path}|${kind}`;
  if (!renders.has(key)) {
    const request = kind === "video"
      ? { op: "render", path, kind: "video", loc: 1, pixels: 360 }
      : { op: "render", path, kind: "image", loc: null, pixels: 360 };
    const itself = kind !== "video" && SHOWN_AS_IS.has(extension) ? fileURL(path) : null;
    renders.set(key, ask(request).then((reply) => (reply && reply.image ? fileURL(reply.image) : itself))
      .catch(() => itself));
  }
  return renders.get(key);
}

const thumbnails = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    const tile = entry.target;
    thumbnails.unobserve(tile);
    picture(tile.dataset.path, tile.dataset.kind).then((url) => {
      if (!url) return;
      const image = element("img");
      image.loading = "lazy";
      image.decoding = "async";
      image.src = url;
      tile.prepend(image);
    });
  }
}, { rootMargin: "300px" });

function tile(path, kind) {
  const node = element("div", "tile");
  node.dataset.path = path;
  node.dataset.kind = kind;
  if (kind === "video") node.append(element("span", "badge", "видео"));
  thumbnails.observe(node);
  return node;
}

// MARK: Pages

function render() {
  const result = state.result;
  const inGroup = state.group != null;
  $("back").hidden = !inGroup;
  $("overview").hidden = inGroup;
  $("groups").hidden = inGroup;
  $("group").hidden = !inGroup;
  $("title").textContent = inGroup ? result.groups[state.group].name || "Группа" : "Анализ фото";
  if (inGroup) return renderGroup(result.groups[state.group]);
  renderOverview();
}

function renderOverview() {
  const overview = $("overview"), groups = $("groups");
  overview.replaceChildren();
  groups.replaceChildren();
  const result = state.result;
  if (!result || !result.groups) {
    const empty = element("div", "empty");
    empty.append(element("h2", null, "Здесь будет анализ ваших фото и видео"));
    empty.append(element("p", null,
      "Выберите папку и нажмите «Анализировать». Программа соберёт похожие фото и видео в группы, а модель сама " +
      "придумает им названия. Результат сохранится — заново ничего гонять не придётся."));
    if (state.info && state.info.folders.length === 0) {
      empty.append(element("p", "error",
        "Сначала добавьте папки в DigUp (меню в трее → Choose Folders…) и дождитесь, пока она их прочитает."));
    }
    overview.append(empty);
    return;
  }
  const stats = element("div", "stats");
  const stat = (big, small) => {
    const node = element("div", "stat");
    node.append(element("b", null, big), element("span", null, small));
    return node;
  };
  const kinds = result.kinds || {};
  stats.append(
    stat(files(result.files), size(result.bytes)),
    stat(String(result.groups.length), plural(result.groups.length, "группа", "группы", "групп")),
    stat(((kinds.image || 0) + (kinds.screenshot || 0)).toLocaleString("ru-RU"), "фото и картинок"),
    stat((kinds.screenshot || 0).toLocaleString("ru-RU"), "из них скриншотов"),
    stat((kinds.video || 0).toLocaleString("ru-RU"), "видео"),
  );
  overview.append(stats);

  const years = Object.entries(result.years || {}).sort(([a], [b]) => a - b);
  if (years.length > 1) {
    overview.append(element("h3", null, "По годам"));
    const chart = element("div", "years");
    const most = Math.max(...years.map(([, n]) => n));
    for (const [year, n] of years) {
      const column = element("div");
      const bar = element("i");
      bar.style.height = `${Math.max(3, (n / most) * 100)}%`;
      column.title = `${year}: ${files(n)}`;
      column.append(bar, element("small", null, year));
      chart.append(column);
    }
    overview.append(chart);
  }
  overview.append(element("h3", null, "Что на фото и видео"));

  result.groups.forEach((group, index) => {
    const card = element("div", "card");
    const thumbs = element("div", "thumbs");
    const kindOf = new Map((group.members || []).map((member) => [member.path, member.kind]));
    for (const path of (group.samples || []).slice(0, 6)) thumbs.append(tile(path, kindOf.get(path) || "image"));
    const about = element("div", "about");
    about.append(element("div", "name", group.name || "Модель ещё думает…"));
    about.append(element("div", "meta", `${files(group.count)} · ${size(group.bytes)}`));
    card.append(thumbs, about);
    card.onclick = () => { state.group = index; render(); $("main").scrollTop = 0; };
    groups.append(card);
  });
}

function renderGroup(group) {
  const grid = $("group");
  grid.replaceChildren();
  const hint = element("p", "hint",
    `${files(group.count)} · ${size(group.bytes)}. Двойной щелчок — открыть, правый — показать в папке.`);
  hint.style.gridColumn = "1 / -1";
  grid.append(hint);
  for (const member of group.members || []) {
    const node = tile(member.path, member.kind);
    node.title = `${nameOf(member.path)} · ${size(member.size)}`;
    node.ondblclick = () => invoke("open_path", { path: member.path, page: null, seconds: null }).catch(() => {});
    node.oncontextmenu = (event) => {
      event.preventDefault();
      invoke("reveal", { path: member.path }).catch(() => {});
    };
    grid.append(node);
  }
}

// MARK: Running

function showProgress(event) {
  const progress = $("progress"), text = $("progress-text"), bar = $("progress-bar");
  if (!state.running) { progress.hidden = true; return; }
  progress.hidden = false;
  const stage = state.stage || "reading";
  let line = STAGES[stage] || "Анализирую…";
  let fraction = null;
  if (stage === "downloading" && state.download) {
    fraction = state.download.bytes / state.download.total;
    line += ` ${size(state.download.bytes)} из ${size(state.download.total)}`;
  }
  if (stage === "naming" && state.named) {
    fraction = state.named.done / state.named.total;
    line += ` ${state.named.done} из ${state.named.total}`;
  }
  text.textContent = line;
  bar.parentElement.hidden = fraction == null;
  if (fraction != null) bar.style.width = `${Math.round(fraction * 100)}%`;
  $("run").disabled = true;
}

async function reload() {
  state.info = await invoke("analysis_info");
  state.result = state.info.result;
  if (state.group != null && (!state.result || !state.result.groups[state.group])) state.group = null;
  render();
}

function onEvent(event) {
  switch (event.event) {
    case "stage":
      state.running = true;
      state.stage = event.stage;
      if (event.stage === "naming") reload();
      break;
    case "progress":
      state.download = { bytes: event.all_bytes, total: event.all_total };
      break;
    case "named":
      state.named = { done: event.done, total: event.total };
      if (state.result && state.result.groups[event.group]) {
        state.result.groups[event.group].name = event.name;
        if (state.group == null) renderOverview();
      }
      break;
    case "done":
      state.running = false;
      $("run").disabled = false;
      reload();
      break;
    case "error":
    case "stopped": {
      state.running = false;
      $("run").disabled = false;
      const progress = $("progress");
      progress.hidden = false;
      $("progress-text").textContent = `Не получилось: ${event.message || "анализ прервался"}`;
      $("progress-text").className = "error";
      return;
    }
  }
  $("progress-text").className = "";
  showProgress();
}

function fillFolders() {
  const select = $("folder");
  const chosen = select.value;
  select.replaceChildren();
  const all = element("option", null, "Все папки DigUp");
  all.value = "";
  select.append(all);
  for (const folder of state.info.folders) {
    const option = element("option", null, folder);
    option.value = folder;
    select.append(option);
  }
  const other = element("option", null, "Другая папка внутри них…");
  other.value = "?";
  select.append(other);
  select.value = [...select.options].some((option) => option.value === chosen) ? chosen : "";
}

$("folder").onchange = async () => {
  const select = $("folder");
  if (select.value !== "?") return;
  const picked = await invoke("analysis_folder");
  if (picked) {
    const option = element("option", null, picked);
    option.value = picked;
    select.insertBefore(option, select.lastElementChild);
    select.value = picked;
  } else {
    select.value = "";
  }
};

$("run").onclick = async () => {
  const folder = $("folder").value;
  state.running = true;
  state.stage = "reading";
  state.download = null;
  state.named = null;
  showProgress();
  try {
    await invoke("analysis_run", { folders: folder && folder !== "?" ? [folder] : [] });
  } catch (error) {
    onEvent({ event: "error", message: String(error) });
  }
};

$("back").onclick = () => { state.group = null; render(); };
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && state.group != null) { state.group = null; render(); }
});

tauri.event.listen("analysis", ({ payload }) => onEvent(payload));

(async () => {
  await reload();
  fillFolders();
  const running = state.info.state;
  if (running && running.state === "running") {
    state.running = true;
    state.stage = running.stage;
    state.download = running.download ? { bytes: running.download.bytes, total: running.download.total } : null;
    state.named = running.named || null;
    showProgress();
  }
})();
