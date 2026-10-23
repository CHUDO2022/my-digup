// The photo analysis window (своя версия): pick a folder, run `digup analyze`, and see what the pictures and videos
// are about — groups of alike files a model named — and what may be junk (copies, series, blurry, dark, short videos,
// screenshots, heavy videos). Files can be picked and moved into quarantine or another folder, and brought back.
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const ask = (request) => invoke("ask", { request });
const fileURL = (path) => tauri.core.convertFileSrc(path);
const $ = (id) => document.getElementById(id);

const SHOWN_AS_IS = new Set(["jpg", "jpeg", "png", "gif", "webp", "bmp"]);
const STAGES = {
  reading: "Читаю, что программа уже знает о файлах…",
  grouping: "Собираю похожие файлы в группы…",
  duplicates: "Ищу одинаковые файлы…",
  quality: "Оцениваю резкость и яркость фото…",
  downloading: "Скачиваю модель, которая придумывает названия (3,3 ГБ, один раз)…",
  loading: "Загружаю модель…",
  naming: "Модель смотрит на группы и придумывает названия…",
};
/// The junk lists, in the order shown: what each is, and whether its files come in sets with one to keep.
const JUNK = [
  { key: "duplicates", title: "Точные копии", sets: true,
    about: "Одинаковые файлы в нескольких местах. Отмечены лишние копии, самая старая остаётся." },
  { key: "series", title: "Серии похожих снимков", sets: true,
    about: "Почти одинаковые кадры одной сцены. Отмечены все, кроме самого резкого." },
  { key: "blurry", title: "Размытые фото",
    about: "Смазанные или не в фокусе. Проверьте глазами: размытость бывает задумкой." },
  { key: "dark", title: "Тёмные фото", about: "Почти чёрные кадры: снято в кармане, с закрытой камерой." },
  { key: "washed", title: "Пересвеченные фото", about: "Почти белые кадры." },
  { key: "shortVideos", title: "Короткие видео", about: "Видео короче 3 секунд — чаще всего случайные." },
  { key: "screenshots", title: "Скриншоты", about: "Все скриншоты, старые первыми." },
  { key: "heavy", title: "Самые тяжёлые видео", about: "Видео больше 100 МБ, от самых больших." },
];

const state = {
  info: null, result: null, tab: "groups", view: null, running: false,
  selected: new Set(), journal: [], files: new Map(),
};

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
const folderOf = (path) => path.slice(0, Math.max(0, path.search(/[\\/][^\\/]*$/)));
const sizeOf = (path) => state.files.get(path)?.size || 0;
const kindOf = (path) => state.files.get(path)?.kind || "image";
const bytesOf = (paths) => paths.reduce((sum, path) => sum + sizeOf(path), 0);

// MARK: Thumbnails

/// A small JPEG from the helper (a photo straight from the camera is megabytes: a grid of them would crawl); the file
/// itself when the helper can't, and it's a picture the web view shows.
const renders = new Map();
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
      image.decoding = "async";
      image.src = url;
      tile.prepend(image);
    });
  }
}, { rootMargin: "300px" });

function tile(path, options = {}) {
  const kind = kindOf(path);
  const node = element("div", "tile" + (options.className ? ` ${options.className}` : ""));
  node.dataset.path = path;
  node.dataset.kind = kind;
  if (kind === "video") node.append(element("span", "badge", "видео"));
  if (options.keep) node.append(element("span", "keep", "оставить"));
  if (options.selectable) {
    node.append(element("span", "check"));
    node.classList.toggle("selected", state.selected.has(path));
    node.onclick = () => toggle(path, node);
    node.ondblclick = (event) => { event.stopPropagation(); open(path); };
  } else {
    node.ondblclick = () => open(path);
  }
  node.oncontextmenu = (event) => { event.preventDefault(); invoke("reveal", { path }).catch(() => {}); };
  node.title = `${nameOf(path)} · ${size(sizeOf(path))}\nДвойной щелчок — открыть, правый — показать в папке`;
  thumbnails.observe(node);
  return node;
}

const open = (path) => invoke("open_path", { path, page: null, seconds: null }).catch(() => {});

// MARK: Selection

function toggle(path, node) {
  if (state.selected.has(path)) state.selected.delete(path);
  else state.selected.add(path);
  node.classList.toggle("selected", state.selected.has(path));
  renderActions();
}

/// The files the open view can act on.
function viewPaths() {
  const view = state.view;
  if (!view) return [];
  if (view.type === "group") return state.result.groups[view.index].members.map((member) => member.path);
  if (view.type === "cluster") return view.groups.flatMap((index) => state.result.groups[index].members.map((member) => member.path));
  const list = state.result.junk?.[view.key] || [];
  const junk = JUNK.find((item) => item.key === view.key);
  return junk?.sets ? list.flatMap((set) => [set.keep, ...set.extra]) : list;
}

function renderActions() {
  const shown = state.view != null;
  $("actions").hidden = !shown;
  if (!shown) return;
  const count = state.selected.size;
  $("selected-text").textContent = count
    ? `Выбрано: ${files(count)} · ${size(bytesOf([...state.selected]))}`
    : "Щёлкните по файлам, чтобы выбрать";
  $("move").disabled = $("quarantine").disabled = count === 0;
}

$("select-all").onclick = () => { for (const path of viewPaths()) state.selected.add(path); render(); };
$("select-none").onclick = () => { state.selected.clear(); render(); };

$("quarantine").onclick = () => take(null);
$("move").onclick = async () => {
  const folder = await invoke("analysis_folder");
  if (folder) take(folder);
};

async function take(folder) {
  const paths = [...state.selected];
  if (!paths.length) return;
  $("quarantine").disabled = $("move").disabled = true;
  const reply = await invoke("files_take", { paths, folder }).catch((error) => ({ moved: [], failed: [{ error: String(error) }] }));
  forget(reply.moved || []);
  const where = folder ? `в «${nameOf(folder)}»` : "в карантин";
  let text = `${files((reply.moved || []).length)} ${where}`;
  if (reply.failed?.length) text += ` · не получилось: ${reply.failed.length} (${reply.failed[0].error})`;
  toast(text, "Открыть карантин", () => { state.view = null; state.tab = "quarantine"; render(); });
  render();
}

/// Moved files leave the groups and the junk lists (the next analysis would drop them too).
function forget(paths) {
  const gone = new Set(paths);
  for (const path of paths) state.selected.delete(path);
  const result = state.result;
  if (!result) return;
  for (const group of result.groups) {
    const before = group.members.length;
    group.members = group.members.filter((member) => !gone.has(member.path));
    if (group.members.length !== before) {
      group.count = group.members.length;
      group.bytes = group.members.reduce((sum, member) => sum + member.size, 0);
      group.samples = (group.samples || []).filter((path) => !gone.has(path));
    }
  }
  for (const junk of JUNK) {
    const list = result.junk?.[junk.key];
    if (!list) continue;
    result.junk[junk.key] = junk.sets
      ? list.map((set) => ({ keep: set.keep, extra: set.extra.filter((path) => !gone.has(path)) }))
          .filter((set) => set.extra.length && !gone.has(set.keep))
      : list.filter((path) => !gone.has(path));
  }
}

let toastTimer = null;
function toast(text, actionText, action) {
  const node = $("toast");
  node.replaceChildren(text);
  if (actionText) {
    const button = element("button", null, actionText);
    button.onclick = () => { node.hidden = true; action(); };
    node.append(button);
  }
  node.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { node.hidden = true; }, 7000);
}

// MARK: Pages

function render() {
  const main = $("main");
  main.replaceChildren();
  const view = state.view;
  $("back").hidden = !view;
  $("tabs").hidden = Boolean(view);
  $("rename").hidden = !(view && view.type === "group");
  for (const button of $("tabs").querySelectorAll("button")) button.classList.toggle("selected", button.dataset.tab === state.tab);
  $("title").textContent = !view ? "Анализ фото"
    : view.type === "group" ? state.result.groups[view.index].name || "Группа"
    : view.type === "cluster" ? clusterName(view.groups, view.groups.map((index) => state.result.groups[index]).sort((a, b) => b.count - a.count))
    : JUNK.find((item) => item.key === view.key).title;
  renderActions();
  if (state.tab === "quarantine" && !view) return renderQuarantine(main);
  if (!state.result || !state.result.groups) return renderEmpty(main);
  if (view?.type === "group") return renderGroup(main, state.result.groups[view.index]);
  if (view?.type === "cluster") return renderCluster(main, view.groups);
  if (view?.type === "junk") return renderJunkList(main, view.key);
  if (state.tab === "junk") return renderJunk(main);
  renderOverview(main);
}

function renderEmpty(main) {
  const empty = element("div", "empty");
  empty.append(element("h2", null, "Здесь будет анализ ваших фото и видео"));
  empty.append(element("p", null,
    "Выберите папку и нажмите «Анализировать». Программа соберёт похожие фото и видео в группы, модель сама " +
    "придумает им названия, а во вкладке «Мусор» появятся копии, серии, размытые и тёмные фото, случайные видео. " +
    "Результат сохранится — заново ничего гонять не придётся."));
  if (state.info && state.info.folders.length === 0) {
    empty.append(element("p", "error",
      "Сначала добавьте папки (меню в трее → «Выбрать папки…») и дождитесь, пока программа их просмотрит."));
  }
  main.append(empty);
}

function stat(big, small) {
  const node = element("div", "stat");
  node.append(element("b", null, big), element("span", null, small));
  return node;
}

function renderOverview(main, keep) {
  const result = state.result;
  if (keep) {
    // The slider moved: only the cards change (the slider keeps its focus).
    const old = main.querySelector(".groups");
    const label = main.querySelector(".level b");
    if (old && label) {
      label.textContent = `${state.level} ${plural(state.level, "группа", "группы", "групп")}`;
      const fresh = document.createElement("div");
      renderGroupsInto(fresh);
      old.replaceWith(fresh.firstChild);
      return;
    }
  }
  const stats = element("div", "stats");
  const kinds = result.kinds || {};
  stats.append(
    stat(files(result.files), size(result.bytes)),
    stat(String(result.groups.length), plural(result.groups.length, "группа", "группы", "групп")),
    stat(((kinds.image || 0) + (kinds.screenshot || 0)).toLocaleString("ru-RU"), "фото и картинок"),
    stat((kinds.screenshot || 0).toLocaleString("ru-RU"), "из них скриншотов"),
    stat((kinds.video || 0).toLocaleString("ru-RU"), "видео"),
  );
  main.append(stats);

  const years = Object.entries(result.years || {}).sort(([a], [b]) => a - b);
  if (years.length > 1) {
    main.append(element("h3", null, "По годам"));
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
    main.append(chart);
  }
  const heading = element("div", "level");
  heading.append(element("h3", null, "Что на фото и видео"));
  const leaves = result.groups.filter((group) => !group.misc && group.members.length).length;
  if (leaves > 2 && result.merges?.length) {
    const slider = element("input");
    slider.type = "range";
    slider.min = 2;
    slider.max = leaves;
    slider.value = state.level = Math.min(Math.max(2, state.level ?? (result.sections?.length || leaves)), leaves);
    slider.oninput = () => { state.level = Number(slider.value); renderOverview(main, true); };
    const label = element("label", "slider");
    label.append(element("span", null, "Крупнее"), slider, element("span", null, "Подробнее"),
                 element("b", null, `${state.level} ${plural(state.level, "группа", "группы", "групп")}`));
    heading.append(label);
  }
  main.append(heading);
  renderGroupsInto(main);
}

/// The cards of the groups (or of merged groups, as the slider has them).
function renderGroupsInto(main) {
  const result = state.result;
  const groups = element("section", "groups");
  for (const cluster of clusters()) {
    const parts = cluster.map((index) => result.groups[index]).filter((group) => group.members.length);
    if (!parts.length) continue;
    parts.sort((a, b) => b.count - a.count);
    const card = element("div", "card");
    const thumbs = element("div", "thumbs");
    const samples = parts.length === 1 ? (parts[0].samples || []).slice(0, 6)
      : parts.flatMap((group) => (group.samples || []).slice(0, Math.max(1, Math.ceil(6 / parts.length)))).slice(0, 6);
    for (const path of samples) thumbs.append(tile(path));
    const about = element("div", "about");
    about.append(element("div", "name", clusterName(cluster, parts)));
    const count = parts.reduce((sum, group) => sum + group.count, 0);
    const bytes = parts.reduce((sum, group) => sum + group.bytes, 0);
    about.append(element("div", "meta", (parts.length > 1 ? `${parts.length} ${plural(parts.length, "группа", "группы", "групп")} · ` : "")
                                        + `${files(count)} · ${size(bytes)}`));
    card.append(thumbs, about);
    card.onclick = () => openView(cluster.length === 1 ? { type: "group", index: cluster[0] } : { type: "cluster", groups: cluster });
    groups.append(card);
  }
  main.append(groups);
}

/// The groups as the slider has them: the first merges applied until `state.level` are left ("Разное" apart, last).
function clusters() {
  const result = state.result;
  const leaves = result.groups.map((group, index) => index).filter((index) => !result.groups[index].misc);
  const parts = new Map(leaves.map((index) => [index, [index]]));
  const target = state.level ?? leaves.length;
  for (const merge of result.merges || []) {
    if (parts.size <= target) break;
    if (!parts.has(merge.a) || !parts.has(merge.b)) continue;
    parts.set(merge.into, [...parts.get(merge.a), ...parts.get(merge.b)]);
    parts.delete(merge.a);
    parts.delete(merge.b);
  }
  const list = [...parts.values()].sort((a, b) => sizeOfCluster(b) - sizeOfCluster(a));
  const misc = result.groups.findIndex((group) => group.misc);
  if (misc >= 0) list.push([misc]);
  return list;
}

const sizeOfCluster = (cluster) => cluster.reduce((sum, index) => sum + (state.result.groups[index].count || 0), 0);

/// A section's name when the cluster is one (the model named it); else the biggest group's name and how many more.
function clusterName(cluster, parts) {
  if (cluster.length === 1) return parts[0].name || "Модель ещё думает…";
  const key = [...cluster].sort((a, b) => a - b).join(",");
  const section = (state.result.sections || []).find((item) => [...item.groups].sort((a, b) => a - b).join(",") === key);
  if (section?.name) return section.name;
  return `${parts[0].name || "Группа"} и ещё ${parts.length - 1}`;
}

function renderCluster(main, cluster) {
  const parts = cluster.map((index) => [index, state.result.groups[index]]).filter(([, group]) => group.members.length)
    .sort(([, a], [, b]) => b.count - a.count);
  const grid = element("section", "grid");
  for (const [index, group] of parts) {
    const title = element("div", "set link", `${group.name || "Группа"} · ${files(group.count)} · ${size(group.bytes)} ›`);
    title.onclick = () => openView({ type: "group", index });
    grid.append(title);
    for (const member of group.members) grid.append(tile(member.path, { selectable: true }));
  }
  main.append(grid);
}

function renderGroup(main, group) {
  const grid = element("section", "grid");
  for (const member of group.members) grid.append(tile(member.path, { selectable: true }));
  main.append(grid);
}

function junkPaths(key) {
  const list = state.result.junk?.[key] || [];
  return JUNK.find((item) => item.key === key)?.sets ? list.flatMap((set) => set.extra) : list;
}

function renderJunk(main) {
  const junk = state.result.junk;
  if (!junk || !Object.keys(junk).length) {
    main.append(element("div", "empty", "Мусор ещё ищется — подождите, пока закончится анализ."));
    return;
  }
  const extra = new Set(["duplicates", "series", "blurry", "dark", "washed", "shortVideos"].flatMap(junkPaths));
  const free = element("p", "free");
  free.append("Если убрать копии, лишние кадры серий, размытые, тёмные, пересвеченные фото и короткие видео, освободится ",
              element("b", null, size(bytesOf([...extra]))), ` (${files(extra.size)}).`);
  main.append(free);
  const cards = element("section", "junk");
  for (const item of JUNK) {
    const paths = junkPaths(item.key);
    const card = element("div", "card" + (paths.length ? "" : " empty-card"));
    card.append(element("div", "name", item.title), element("p", null, item.about));
    const line = element("div");
    line.append(element("b", null, paths.length ? files(paths.length) : "нет"),
                paths.length ? ` · ${size(bytesOf(paths))}` : "");
    card.append(line);
    if (paths.length) card.onclick = () => openView({ type: "junk", key: item.key });
    cards.append(card);
  }
  main.append(cards);
  if (junk.measured === 0) {
    main.append(element("p", "hint", "Резкость и яркость не оценены: эти фото программа прочитать не смогла."));
  }
}

function renderJunkList(main, key) {
  const item = JUNK.find((entry) => entry.key === key);
  const list = state.result.junk?.[key] || [];
  main.append(element("p", "hint", item.about + " Щелчок — выбрать, двойной — открыть, правый — показать в папке."));
  const grid = element("section", "grid");
  if (item.sets) {
    list.forEach((set, index) => {
      grid.append(element("div", "set", `${index + 1}. ${files(set.extra.length + 1)}`));
      grid.append(tile(set.keep, { selectable: true, keep: true }));
      for (const path of set.extra) grid.append(tile(path, { selectable: true }));
    });
  } else {
    for (const path of list) grid.append(tile(path, { selectable: true }));
  }
  main.append(grid);
}

async function renderQuarantine(main) {
  state.journal = await invoke("files_journal").catch(() => []);
  main.replaceChildren();
  const entries = [...state.journal].sort((a, b) => b.at - a.at);
  if (!entries.length) {
    main.append(element("div", "empty", "Здесь пока пусто. Файлы, убранные в карантин или перемещённые в другую " +
      "папку, появятся здесь — их можно вернуть на место."));
    return;
  }
  const quarantined = entries.filter((entry) => entry.kind === "quarantine");
  const free = element("p", "free");
  free.append("В карантине ", element("b", null, files(quarantined.length)), ` · ${size(quarantined.reduce((s, e) => s + e.size, 0))}. ` +
              "Пока файлы здесь, место не освобождено — удалите навсегда, когда будете уверены.");
  main.append(free);
  const chosen = new Set();
  const buttons = element("div", "bar-buttons");
  const restore = element("button", null, "Вернуть на место");
  const purge = element("button", "danger", "Удалить навсегда");
  const all = element("button", null, "Выбрать всё");
  const update = () => {
    restore.disabled = purge.disabled = chosen.size === 0;
    restore.textContent = chosen.size ? `Вернуть на место (${chosen.size})` : "Вернуть на место";
  };
  buttons.append(all, restore, purge);
  main.append(buttons);
  const rows = element("div", "rows");
  for (const entry of entries) {
    const row = element("label", "row");
    const box = element("input");
    box.type = "checkbox";
    box.onchange = () => { box.checked ? chosen.add(entry.id) : chosen.delete(entry.id); update(); };
    const thumb = element("div", "tile thumb");
    thumb.dataset.path = entry.stored;
    thumb.dataset.kind = /\.(mp4|mov|m4v|mkv|webm|avi|wmv|3gp|mpg|mpeg)$/i.test(entry.stored) ? "video" : "image";
    thumbnails.observe(thumb);
    const what = element("div", "what");
    what.append(element("div", null, nameOf(entry.original)),
                element("div", "from", (entry.kind === "quarantine" ? "в карантине · было в " : "перемещён в " +
                  folderOf(entry.stored) + " · был в ") + folderOf(entry.original) + " · " +
                  new Date(entry.at * 1000).toLocaleString("ru-RU")));
    row.append(box, thumb, what, element("span", "size", size(entry.size)));
    row.ondblclick = () => invoke("open_path", { path: entry.stored, page: null, seconds: null }).catch(() => {});
    rows.append(row);
  }
  main.append(rows);
  all.onclick = () => {
    for (const entry of entries) chosen.add(entry.id);
    for (const box of rows.querySelectorAll("input")) box.checked = true;
    update();
  };
  restore.onclick = async () => {
    const reply = await invoke("files_restore", { ids: [...chosen] }).catch((error) => ({ restored: [], failed: [{ error: String(error) }] }));
    toast(`Возвращено: ${files(reply.restored.length)}` + (reply.failed.length ? ` · не получилось: ${reply.failed.length}` : "") +
          ". Запустите анализ ещё раз, чтобы они снова попали в группы.");
    render();
  };
  purge.onclick = async () => {
    const picked = entries.filter((entry) => chosen.has(entry.id) && entry.kind === "quarantine");
    if (!picked.length) { toast("Удалить навсегда можно только файлы из карантина."); return; }
    const sure = window.confirm(`Удалить навсегда ${files(picked.length)} (${size(picked.reduce((s, e) => s + e.size, 0))})? ` +
                                "Вернуть их будет нельзя.");
    if (!sure) return;
    const reply = await invoke("files_purge", { ids: picked.map((entry) => entry.id) }).catch(() => ({ bytes: 0, failed: [] }));
    toast(`Удалено навсегда, освобождено ${size(reply.bytes)}` + (reply.failed.length ? ` · не получилось: ${reply.failed.length}` : ""));
    render();
  };
  update();
}

function openView(view) {
  state.view = view;
  state.selected.clear();
  if (view.type === "junk") {
    // Sets come with their extras picked: what's suggested to go.
    const item = JUNK.find((entry) => entry.key === view.key);
    if (item.sets) for (const path of junkPaths(view.key)) state.selected.add(path);
  }
  render();
  $("main").scrollTop = 0;
}

function closeView() {
  state.view = null;
  state.selected.clear();
  render();
}

$("back").onclick = closeView;
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && state.view && document.activeElement?.tagName !== "INPUT") closeView();
});
for (const button of $("tabs").querySelectorAll("button")) {
  button.onclick = () => { state.tab = button.dataset.tab; state.view = null; render(); };
}

$("rename").onclick = () => {
  const view = state.view;
  if (!view || view.type !== "group") return;
  const group = state.result.groups[view.index];
  const input = element("input", "title-edit");
  input.value = group.name || "";
  $("title").replaceChildren(input);
  input.focus();
  input.select();
  const done = async (save) => {
    if (save && input.value.trim()) {
      group.name = input.value.trim();
      await invoke("analysis_rename", { id: group.id, name: group.name }).catch(() => {});
    }
    render();
  };
  input.onkeydown = (event) => {
    if (event.key === "Enter") done(true);
    if (event.key === "Escape") { event.stopPropagation(); done(false); }
  };
  input.onblur = () => done(true);
};

// MARK: Running

function showProgress() {
  const progress = $("progress"), text = $("progress-text"), bar = $("progress-bar");
  if (!state.running) { progress.hidden = true; $("run").disabled = false; return; }
  progress.hidden = false;
  $("ring").hidden = false;
  text.className = "";
  const stage = state.stage || "reading";
  let line = STAGES[stage] || "Анализирую…";
  let fraction = null;
  if (stage === "downloading" && state.download) {
    fraction = state.download.bytes / state.download.total;
    line += ` ${size(state.download.bytes)} из ${size(state.download.total)}`;
  }
  if (stage === "quality" && state.measured) {
    fraction = state.measured.done / state.measured.total;
    line += ` ${state.measured.done.toLocaleString("ru-RU")} из ${state.measured.total.toLocaleString("ru-RU")}`;
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

function indexFiles() {
  state.files = new Map();
  for (const group of state.result?.groups || []) {
    for (const member of group.members || []) state.files.set(member.path, member);
  }
}

async function reload() {
  state.info = await invoke("analysis_info");
  state.result = state.info.result;
  indexFiles();
  if (state.view?.type === "group" && !state.result?.groups?.[state.view.index]) state.view = null;
  render();
}

function onEvent(event) {
  switch (event.event) {
    case "stage":
      state.running = true;
      state.stage = event.stage;
      if (["duplicates", "naming"].includes(event.stage) && !state.view) reload();
      break;
    case "progress":
      state.download = { bytes: event.all_bytes, total: event.all_total };
      break;
    case "measured":
      state.measured = { done: event.done, total: event.total };
      break;
    case "named":
      state.named = { done: event.done, total: event.total };
      if (state.result && state.result.groups[event.group] && !state.result.groups[event.group].custom) {
        state.result.groups[event.group].name = event.name;
        if (!state.view && state.tab === "groups") render();
      }
      break;
    case "done":
      state.running = false;
      if (!state.view) reload();
      break;
    case "error":
    case "stopped":
      state.running = false;
      $("run").disabled = false;
      $("progress").hidden = false;
      $("ring").hidden = true;
      $("progress-bar").parentElement.hidden = true;
      $("progress-text").textContent = `Не получилось: ${event.message || "анализ прервался"}`;
      $("progress-text").className = "error";
      return;
  }
  showProgress();
}

function fillFolders() {
  const select = $("folder");
  const chosen = select.value;
  select.replaceChildren();
  const all = element("option", null, "Все папки");
  all.value = "";
  select.append(all);
  for (const folder of state.info.folders) {
    const option = element("option", null, folder);
    option.value = folder;
    select.append(option);
  }
  const other = element("option", null, "Папка внутри них…");
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
  Object.assign(state, { running: true, stage: "reading", download: null, named: null, measured: null });
  showProgress();
  try {
    await invoke("analysis_run", { folders: folder && folder !== "?" ? [folder] : [] });
  } catch (error) {
    onEvent({ event: "error", message: String(error) });
  }
};

tauri.event.listen("analysis", ({ payload }) => onEvent(payload));

(async () => {
  await reload();
  fillFolders();
  const running = state.info.state;
  if (running && running.state === "running") {
    Object.assign(state, {
      running: true, stage: running.stage, download: running.download || null, named: running.named || null,
      measured: running.measured || null,
    });
    showProgress();
  }
})();
