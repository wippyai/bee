/* Bee desktop simulator. Cell-accurate reproduction of the Bee presenter,
   bar, Start menu, window chrome and bundled applications, drawn on a canvas. */
(function () {
  "use strict";

  // ---------------------------------------------------------------- appearance
  const THEMES = [
    { id: "honey", title: "Honey", ground: "#0c1119", surface: "#17202c", text: "#d8e2ef", muted: "#8999ad", border: "#6f89a5", accent: "#ffc963", pattern: "#1c2937" },
    { id: "ocean", title: "Ocean", ground: "#071720", surface: "#102b39", text: "#d6f0f4", muted: "#88adb9", border: "#4b8599", accent: "#67dce5", pattern: "#1a3542" },
    { id: "forest", title: "Forest", ground: "#101a16", surface: "#1c2b23", text: "#e0ecdf", muted: "#96af9e", border: "#628773", accent: "#b6d884", pattern: "#283c30" },
    { id: "plum", title: "Plum", ground: "#19121f", surface: "#2b2034", text: "#eee0f2", muted: "#b2a0bd", border: "#9478a6", accent: "#e4acf1", pattern: "#34243e" },
    { id: "ember", title: "Ember", ground: "#1c1311", surface: "#30201c", text: "#f4e4d8", muted: "#bda598", border: "#a87964", accent: "#ffa879", pattern: "#3a2820" },
    { id: "graphite", title: "Graphite", ground: "#111315", surface: "#222629", text: "#e8edef", muted: "#a0a9ae", border: "#76828a", accent: "#c3d8e6", pattern: "#2b3034" },
    { id: "paper", title: "Paper", ground: "#e9e6dd", surface: "#f5f2ea", text: "#303b3e", muted: "#58666b", border: "#7d8785", accent: "#87560c", pattern: "#cfcec6" },
    { id: "aurora", title: "Aurora", ground: "#0b1720", surface: "#152b35", text: "#def7ed", muted: "#91b8ad", border: "#578f89", accent: "#82f0ba", pattern: "#203a43" },
    { id: "rose", title: "Rose", ground: "#21131c", surface: "#38212e", text: "#f8e5ed", muted: "#c9a1b4", border: "#a7748d", accent: "#ffa5c5", pattern: "#422839" },
    { id: "cobalt", title: "Cobalt", ground: "#0c142b", surface: "#192749", text: "#e0eaff", muted: "#9cadcf", border: "#667fae", accent: "#87b6ff", pattern: "#24365b" },
    { id: "sand", title: "Sand", ground: "#e8dcc8", surface: "#f4ead9", text: "#493e30", muted: "#72634e", border: "#9e8b6e", accent: "#9e4e28", pattern: "#cec1a9" },
    { id: "midnight", title: "Midnight", ground: "#07090e", surface: "#141822", text: "#e0e5f0", muted: "#929db5", border: "#5d6c89", accent: "#c1b5ff", pattern: "#202638" },
    { id: "lavender", title: "Lavender", ground: "#e8e2f0", surface: "#f5effb", text: "#42394f", muted: "#75677f", border: "#9b8eaa", accent: "#75509d", pattern: "#d0c5dc" },
    { id: "mono", title: "Mono", ground: "#0d0d0d", surface: "#242424", text: "#ededed", muted: "#aaaaaa", border: "#777777", accent: "#ffffff", pattern: "#2b2b2b" },
    { id: "dos", title: "DOS Blue", ground: "#000080", surface: "#0000aa", text: "#ffffff", muted: "#aaaaaa", border: "#55ffff", accent: "#ffff55", pattern: "#0000aa" },
    { id: "classic", title: "Windows Classic", ground: "#008080", surface: "#c0c0c0", text: "#000000", muted: "#505050", border: "#606060", accent: "#000080", pattern: "#006b6b", on_accent: "#ffffff", terminal_text: "#cccccc", terminal_surface: "#0c0c0c" },
  ];
  const BACKGROUNDS = ["dots", "solid", "grid", "horizon", "stars", "weave", "crosshatch", "bricks", "diagonal", "waves", "hex"];
  const PATTERNS = {
    dots: { period: 8, rows: ["        ", "   ·    ", "        "] },
    grid: { period: 4, rows: ["┼───", "│   "] },
    stars: { period: 8, rows: ["+       ", "    ·   ", "        ", "  ·     "] },
    weave: { period: 8, rows: ["──  │   ", "    │   ", "│   ──  ", "│       "] },
    crosshatch: { period: 4, rows: ["╲ ╱ ", " ╳  ", "╱ ╲ ", "    "] },
    bricks: { period: 8, rows: ["────┬───", "    │   ", "┬───┴───", "│       "] },
    diagonal: { period: 4, rows: ["╲   ", " ╲  ", "  ╲ ", "   ╲"] },
    waves: { period: 6, rows: ["∙  ∙  ", " ∙∙ ∙∙", "      "] },
    hex: { period: 4, rows: ["⬡   ", "  ⬡ "] },
  };
  const ACCENT_DARK = { amber: "#ffc963", cyan: "#67dce5", green: "#a6df8a", rose: "#ffa5c5", violet: "#d3b0ff" };
  const ACCENT_LIGHT = { amber: "#9c6200", cyan: "#006d80", green: "#28703a", rose: "#9f3158", violet: "#744394" };

  function theme(id) { return THEMES.find((t) => t.id === id) || THEMES[0]; }
  function selectionText(t) { return t.on_accent || t.ground; }
  function luminance(hex) {
    const r = parseInt(hex.slice(1, 3), 16), g = parseInt(hex.slice(3, 5), 16), b = parseInt(hex.slice(5, 7), 16);
    return r * 0.299 + g * 0.587 + b * 0.114;
  }
  function instanceAccent(t, name) {
    if (!name || !ACCENT_DARK[name]) return [t.accent, selectionText(t)];
    if (luminance(t.surface) > 128) return [ACCENT_LIGHT[name], "#ffffff"];
    return [ACCENT_DARK[name], "#000000"];
  }
  function backgroundRow(id, width, y, height) {
    const p = PATTERNS[id];
    if (p) return p.rows[(y - 1) % p.rows.length].repeat(Math.floor(width / p.period) + 1);
    if (id === "horizon" && y >= (height * 2) / 3 && y % 2 === 0) return "─".repeat(width);
    return " ".repeat(width);
  }
  function page(t, terminal) {
    if (terminal) return { fg: t.terminal_text || t.text, bg: t.terminal_surface || t.surface };
    return { fg: t.text, bg: t.surface };
  }

  // ---------------------------------------------------------------- text helpers
  const chars = (s) => Array.from(s);
  const twidth = (s) => chars(s).length;
  function truncate(s, width, ell) {
    const c = chars(s);
    if (width <= 0) return "";
    if (c.length <= width) return s;
    ell = ell || "";
    if (twidth(ell) >= width) return c.slice(0, width).join("");
    return c.slice(0, width - twidth(ell)).join("") + ell;
  }
  const pad = (s, w) => s + " ".repeat(Math.max(0, w - twidth(s)));
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

  // ---------------------------------------------------------------- cell canvas
  class Cells {
    constructor(w, h) { this.w = w; this.h = h; this.ch = new Array(w * h); this.fg = new Array(w * h); this.bg = new Array(w * h); }
    clear(fg, bg) { this.ch.fill(" "); this.fg.fill(fg); this.bg.fill(bg); }
    put(x, y, text, fg, bg, width) {
      if (y < 1 || y > this.h) return;
      const cs = chars(text);
      const limit = width == null ? cs.length : Math.min(width, cs.length);
      for (let i = 0; i < limit; i++) {
        const cx = x + i;
        if (cx < 1 || cx > this.w) continue;
        const idx = (y - 1) * this.w + (cx - 1);
        this.ch[idx] = cs[i]; this.fg[idx] = fg; this.bg[idx] = bg;
      }
    }
    fill(x, y, w, h, fg, bg, ch) {
      for (let yy = y; yy < y + h; yy++) this.put(x, yy, (ch || " ").repeat(Math.max(0, w)), fg, bg, w);
    }
    blit(src, x, y, w, h) {
      for (let yy = 0; yy < h; yy++) for (let xx = 0; xx < w; xx++) {
        const cx = x + xx, cy = y + yy;
        if (cx < 1 || cx > this.w || cy < 1 || cy > this.h) continue;
        const si = yy * src.w + xx, di = (cy - 1) * this.w + (cx - 1);
        this.ch[di] = src.ch[si]; this.fg[di] = src.fg[si]; this.bg[di] = src.bg[si];
      }
    }
  }

  // ---------------------------------------------------------------- catalog
  const CATALOG = [
    { id: "terminal", title: "Terminal", icon: ">", group: "", role: "terminal" },
    { id: "claude", title: "Claude Code", icon: "C", group: "Agents", role: "terminal" },
    { id: "codex", title: "Codex", icon: "X", group: "Agents", role: "terminal" },
    { id: "inbox", title: "Inbox", icon: "I", group: "Tools", role: "inspection" },
    { id: "settings", title: "Settings", icon: "S", group: "Tools", role: "appearance" },
    { id: "processes", title: "Process Manager", icon: "P", group: "Tools", role: "inspection" },
  ];

  // ---------------------------------------------------------------- desktop state
  const state = {
    width: 80, height: 24,
    prefs: { theme: "honey", background: "dots", taskbar: "labels" },
    windows: [], order: [], zorder: [], focus: "",
    menu: null, dialog: null, capture: null, hover: "default",
    status: "", statusUntil: 0, booting: false, nextId: 1,
    workspace: Math.random().toString(16).slice(2, 10),
  };
  const listeners = [];
  const win = (id) => state.windows.find((w) => w.id === id);
  const visible = () => state.zorder.map(win).filter((w) => w && w.mode !== "minimized");
  const area = () => ({ x: 1, y: 2, width: state.width, height: Math.max(0, state.height - 1) });

  function bounds(w) {
    if (w.mode === "fullscreen") return area();
    if (w.mode === "collapsed") return { x: w.bounds.x, y: w.bounds.y, width: w.bounds.width, height: 1 };
    return w.bounds;
  }
  function place(id, rect) {
    const w = win(id); if (!w) return;
    const a = area();
    const width = clamp(rect.width, 12, a.width), height = clamp(rect.height, 3, a.height);
    const x = clamp(rect.x, 1, a.width - width + 1), y = clamp(rect.y, a.y, a.y + a.height - height);
    w.bounds = { x, y, width, height };
  }
  function focusWindow(id) {
    const w = win(id); if (!w) return;
    if (w.mode === "minimized") w.mode = w.previous || "floating";
    state.focus = id;
    state.zorder = state.zorder.filter((z) => z !== id).concat(id);
  }
  function openApp(defId, options) {
    const def = CATALOG.find((d) => d.id === defId); if (!def) return;
    options = options || {};
    const a = area();
    const count = state.windows.length;
    const width = clamp(Math.round(a.width * 0.62), 40, a.width), height = clamp(Math.round(a.height * 0.72), 10, a.height);
    const id = "w" + state.nextId++;
    const w = { id, def: def.id, title: options.title || def.title, label: "", icon: def.icon, mode: "floating", accent: "", previous: "floating",
      bounds: { x: 3 + (count % 5) * 5, y: a.y + 1 + (count % 5) * 2, width, height }, app: apps[def.id].create(options) };
    state.windows.push(w); state.order.push(id); state.zorder.push(id);
    place(id, w.bounds);
    if (options.fullscreen) w.mode = "fullscreen";
    focusWindow(id);
    setStatus(def.title + " opened");
    return w;
  }
  function closeWindow(id, force) {
    const w = win(id); if (!w) return;
    if (!force && w.def === "terminal" && !w.app.exited) {
      state.dialog = { kind: "confirm", text: "Close Terminal? The shell is still running.", ok: "Close", target: id };
      return;
    }
    state.windows = state.windows.filter((x) => x.id !== id);
    state.order = state.order.filter((x) => x !== id);
    state.zorder = state.zorder.filter((x) => x !== id);
    if (state.focus === id) {
      const top = visible(); state.focus = top.length ? top[top.length - 1].id : "";
    }
    setStatus(w.title + " closed");
  }
  function displayTitle(w) { return w.label || w.title; }
  function setStatus(text, ms) { state.status = text; state.statusUntil = Date.now() + (ms || 2600); }
  function windowAction(id, action) {
    const w = win(id); if (!w) return;
    const a = area();
    switch (action) {
      case "minimize": if (w.mode !== "minimized") { w.previous = w.mode === "collapsed" ? "floating" : w.mode; w.mode = "minimized"; if (state.focus === id) { const top = visible(); state.focus = top.length ? top[top.length - 1].id : ""; } } break;
      case "restore": w.mode = "floating"; focusWindow(id); break;
      case "fullscreen": w.mode = w.mode === "fullscreen" ? "floating" : "fullscreen"; focusWindow(id); break;
      case "collapse": w.mode = w.mode === "collapsed" ? "floating" : "collapsed"; focusWindow(id); break;
      case "snap_left": w.mode = "floating"; place(id, { x: 1, y: a.y, width: Math.floor(a.width / 2), height: a.height }); focusWindow(id); break;
      case "snap_right": w.mode = "floating"; place(id, { x: Math.floor(a.width / 2) + 1, y: a.y, width: a.width - Math.floor(a.width / 2), height: a.height }); focusWindow(id); break;
      case "close": closeWindow(id); break;
      case "rename": state.dialog = { kind: "text", text: "Window label", value: displayTitle(w), ok: "Rename", target: id }; break;
      default:
        if (action.startsWith("accent:")) { w.accent = action.slice(7); }
    }
  }
  function altTab() {
    if (!state.order.length) return;
    const i = state.order.indexOf(state.focus);
    const next = state.order[(i + 1) % state.order.length];
    focusWindow(next);
  }
  function quit() {
    state.windows = []; state.order = []; state.zorder = []; state.focus = ""; state.menu = null; state.dialog = null;
    boot("Bee closed. Starting a fresh workspace…");
  }
  function boot(message) {
    state.booting = true; state.menu = null;
    setStatus(message || "Presenter reloaded, applications kept running", 3000);
    setTimeout(() => { state.booting = false; render(); }, 750);
  }

  // ---------------------------------------------------------------- menu (menu.lua)
  function menuItems(m) {
    if (m.kind === "window") {
      const w = win(m.target); if (!w) return [];
      return descend([
        { label: "Restore", action: "restore", enabled: w.mode !== "floating" },
        { label: "Minimize", shortcut: "Alt+F9", action: "minimize", enabled: w.mode !== "minimized" },
        { label: "Maximize / restore", shortcut: "F11", action: "fullscreen", enabled: w.mode !== "minimized" },
        { label: "Snap left", action: "snap_left", enabled: w.mode !== "minimized" },
        { label: "Snap right", action: "snap_right", enabled: w.mode !== "minimized" },
        { label: "Collapse", action: "collapse", enabled: w.mode === "floating" },
        { label: "Rename…", action: "rename", enabled: true },
        { label: "Accent", action: "group:accent", enabled: true, children: [
          { label: "Theme default", action: "accent:", enabled: true },
          { label: "Amber", action: "accent:amber", enabled: true },
          { label: "Cyan", action: "accent:cyan", enabled: true },
          { label: "Green", action: "accent:green", enabled: true },
          { label: "Rose", action: "accent:rose", enabled: true },
          { label: "Violet", action: "accent:violet", enabled: true },
        ] },
        { label: "Close", shortcut: "Ctrl+W", action: "close", enabled: true },
      ], m.path);
    }
    if (m.kind === "desktop") {
      const items = CATALOG.filter((d) => d.role === "appearance" || d.role === "inspection").map((d) => ({ label: d.title, action: "open:" + d.id, enabled: true }));
      items.push({ label: "Restore windows", action: "restore_all", enabled: state.windows.length > 0 });
      items.push({ label: "Reload desktop", shortcut: "F12", action: "rejoin", enabled: true });
      return items;
    }
    const items = [];
    for (const d of CATALOG) {
      let current = items;
      for (const part of d.group.split("/").filter(Boolean)) {
        let found = current.find((i) => i.children && i.action === "group:" + part);
        if (!found) { found = { label: part, action: "group:" + part, enabled: true, children: [] }; current.push(found); }
        current = found.children;
      }
      current.push({ label: d.title, action: "open:" + d.id, enabled: true });
    }
    if (m.initial) items.unshift({ label: "Open application", shortcut: "Ctrl+N", action: "initial", enabled: true });
    items.push({ label: "Exit", shortcut: "Ctrl+Q", action: "quit", enabled: true });
    return descend(items, m.path);
  }
  function descend(items, path) {
    for (const i of path || []) { const it = items[i - 1]; if (it && it.children) items = it.children; else break; }
    return items;
  }
  function menuPanel(count, m) {
    const width = state.width, height = state.height;
    let y = height >= 4 ? 2 : 1;
    const inset = m && m.path && m.path.length > 0 ? 1 : 0;
    const h = Math.max(1, Math.min(count + 2 + inset, height - y + 1));
    const w = Math.min(35, width);
    let x = 1;
    if (m && m.kind) { x = clamp(m.x || 1, 1, width - w + 1); y = clamp(m.y || y, 1, height - h + 1); }
    return { x, y, width: w, height: h, capacity: Math.max(0, h - 2 - inset), inset };
  }
  function menuFit(m, panel, count) {
    m.selected = clamp(m.selected, 1, Math.max(1, count));
    m.offset = clamp(m.offset, 0, Math.max(0, count - panel.capacity));
    if (m.selected <= m.offset) m.offset = m.selected - 1;
    if (m.selected > m.offset + panel.capacity) m.offset = Math.max(0, m.selected - panel.capacity);
  }
  function menuMove(m, step, items, panel) {
    if (!items.length) return;
    let index = m.selected;
    for (let n = 0; n < items.length; n++) { index = ((index - 1 + step + items.length) % items.length) + 1; if (items[index - 1].enabled) break; }
    m.selected = index; menuFit(m, panel, items.length);
  }
  function menuActivate(m, items, index) {
    const item = items[index - 1]; if (!item || !item.enabled) return "";
    if (item.children) { m.path = (m.path || []).concat(index); m.selected = 1; m.offset = 0; return ""; }
    return item.action;
  }
  function menuBack(m) {
    const path = (m.path || []).slice();
    if (!path.length) { state.menu = null; return; }
    m.selected = path.pop(); m.offset = 0; m.path = path;
  }
  function runMenuAction(action, m) {
    state.menu = null;
    if (action === "quit") quit();
    else if (action === "rejoin") boot();
    else if (action === "initial") state.menu = { kind: null, selected: 1, offset: 0, path: [] };
    else if (action === "restore_all") { for (const w of state.windows) if (w.mode === "minimized") w.mode = "floating"; }
    else if (action.startsWith("open:")) openApp(action.slice(5));
    else if (m.kind === "window") windowAction(m.target, action);
  }
  function menuKey(e) {
    const m = state.menu; const items = menuItems(m); const panel = menuPanel(items.length, m); menuFit(m, panel, items.length);
    if (e.ctrlKey && e.key.toLowerCase() === "q") return runMenuAction("quit", m);
    if (e.ctrlKey && e.key.toLowerCase() === "w" && m.kind === "window") return runMenuAction("close", m);
    switch (e.key) {
      case "ArrowUp": menuMove(m, -1, items, panel); break;
      case "ArrowDown": case "Tab": menuMove(m, 1, items, panel); break;
      case "PageUp": case "PageDown": { const d = e.key === "PageUp" ? -1 : 1; m.selected = clamp(m.selected + d * Math.max(1, panel.capacity), 1, items.length); menuFit(m, panel, items.length); if (!items[m.selected - 1].enabled) menuMove(m, d, items, panel); break; }
      case "Home": m.selected = 1; m.offset = 0; break;
      case "End": m.selected = items.length; menuFit(m, panel, items.length); break;
      case "Enter": { const a = menuActivate(m, items, m.selected); if (a) runMenuAction(a, m); break; }
      case "ArrowRight": { const it = items[m.selected - 1]; if (it && it.children) menuActivate(m, items, m.selected); break; }
      case "ArrowLeft": case "Backspace": case "Escape": menuBack(m); break;
      case "F11": if (items.some((i) => i.action === "fullscreen" && i.enabled)) runMenuAction("fullscreen", m); break;
      case "F12": runMenuAction("rejoin", m); break;
      case "F9": if (e.altKey && items.some((i) => i.action === "minimize" && i.enabled)) runMenuAction("minimize", m); break;
      case "F1": state.menu = null; break;
    }
  }
  function menuHit(panel, m, x, y, count) {
    if (x <= panel.x || x >= panel.x + panel.width - 1 || y < panel.y + 1 + panel.inset || y >= panel.y + panel.height - 1) return 0;
    const index = m.offset + y - panel.y - panel.inset;
    return index >= 1 && index <= count ? index : 0;
  }
  function menuMouse(x, y, button, action) {
    const m = state.menu; const items = menuItems(m); const panel = menuPanel(items.length, m); menuFit(m, panel, items.length);
    const index = menuHit(panel, m, x, y, items.length);
    if (action === "motion") { if (index && items[index - 1].enabled) { m.selected = index; menuFit(m, panel, items.length); } return; }
    if (action === "wheel") { menuMove(m, button > 0 ? 1 : -1, items, panel); return; }
    if (action !== "press") return;
    if (button === 2) { state.menu = null; return; }
    if (panel.inset > 0 && y === panel.y + 1 && x > panel.x && x < panel.x + panel.width - 1) return menuBack(m);
    if (index && items[index - 1].enabled) { m.selected = index; const a = menuActivate(m, items, index); if (a) runMenuAction(a, m); return; }
    if (x < panel.x || x >= panel.x + panel.width || y < panel.y || y >= panel.y + panel.height) {
      state.menu = null;
      if (!(y === 1 && x <= 7)) routePointer(x, y, button, action, true);
    }
  }
  function drawMenu(cv, t) {
    const m = state.menu; const items = menuItems(m); const panel = menuPanel(items.length, m); menuFit(m, panel, items.length);
    const inside = Math.max(0, panel.width - 2);
    for (let y = panel.y; y < panel.y + panel.height; y++) {
      const edge = y === panel.y || y === panel.y + panel.height - 1;
      let row = "│" + " ".repeat(inside) + "│";
      if (edge) row = (y === panel.y ? "╭" : "╰") + "─".repeat(inside) + (y === panel.y ? "╮" : "╯");
      cv.put(panel.x, y, row, t.border, t.surface, panel.width);
    }
    if (panel.height < 3 || panel.width < 4) return;
    if (panel.inset > 0) cv.put(panel.x + 1, panel.y + 1, " ‹ Back", t.text, t.surface, inside);
    for (let row = 1; row <= panel.capacity; row++) {
      const index = m.offset + row; const item = items[index - 1]; if (!item) continue;
      let fg = item.enabled ? t.text : t.muted, bg = t.surface, hintFg = t.muted;
      if (index === m.selected && item.enabled) { fg = selectionText(t); bg = t.accent; hintFg = fg; }
      const available = Math.max(0, inside - 2);
      let hint = item.children ? "›" : item.shortcut || "";
      if (twidth(hint) + 4 > available) hint = "";
      const label = truncate(item.label, Math.max(0, available - twidth(hint) - (hint ? 2 : 0)), "…");
      const gap = " ".repeat(Math.max(0, available - twidth(label) - twidth(hint)));
      const y = panel.y + panel.inset + row;
      cv.put(panel.x + 1, y, " ", t.text, t.surface, 1);
      cv.put(panel.x + 2, y, label + gap, fg, bg);
      cv.put(panel.x + 2 + twidth(label + gap), y, hint, hintFg, bg);
      cv.put(panel.x + 2 + available, y, " ", t.text, t.surface, 1);
    }
  }

  // ---------------------------------------------------------------- bar (bar.lua)
  function tabstrip(width, icons) {
    const labels = [], ids = []; let focused = 1;
    for (const id of state.order) {
      const w = win(id); if (!w) continue;
      let title = truncate(displayTitle(w), Math.max(1, Math.min(22, width - 7)), "…");
      if (icons) { title = truncate(w.icon || title, 2, ""); if (!twidth(title)) title = "•"; }
      const badge = w.mode === "fullscreen" ? "▣ " : w.mode === "minimized" ? "− " : w.mode === "collapsed" ? "▸ " : "";
      labels.push(" " + badge + title + " "); ids.push(id);
      if (w.id === state.focus) focused = labels.length;
    }
    let first = 1, span = 0;
    for (let i = 1; i <= focused; i++) span += twidth(labels[i - 1] || "");
    while (first < focused && span > width - 5) { span -= twidth(labels[first - 1]); first++; }
    let text = " "; const hits = [];
    if (first > 1 && width >= 5) { text = "‹ "; hits.push({ id: ids[first - 2], x: 1, width: 2 }); }
    let last = first - 1;
    for (let i = first; i <= labels.length; i++) {
      const x = twidth(text) + 1;
      const available = width - x + 1 - (i < labels.length ? 2 : 0);
      if (available < 1 || (i > first && twidth(labels[i - 1]) > available)) break;
      const label = truncate(labels[i - 1], available, "…");
      hits.push({ id: ids[i - 1], x, width: twidth(label) }); text += label; last = i;
    }
    if (last < ids.length && twidth(text) + 2 <= width) { hits.push({ id: ids[last], x: twidth(text) + 1, width: 2 }); text += "› "; }
    return { text, hits };
  }
  function drawBar(cv, t) {
    const width = state.width;
    const status = Date.now() < state.statusUntil ? state.status : "";
    const label = "workspace · local host";
    const full = visible().find((w) => w.mode === "fullscreen");
    const restore = full && width >= 36 ? " −  ◇  × " : "";
    let right = "";
    if (status && width >= 36) right = " " + status + " "; else if (width >= 60) right = " " + label + " ";
    right = truncate(right, Math.max(0, Math.floor(width / 2)));
    const room = Math.max(0, width - 7 - twidth(right) - twidth(restore));
    const strip = tabstrip(room, state.prefs.taskbar === "icons");
    const opened = state.menu && !state.menu.kind;
    cv.fill(1, 1, width, 1, t.text, t.surface);
    cv.put(1, 1, opened ? " BEE ▴ " : " BEE ▾ ", selectionText(t), t.accent, 7);
    const hits = [];
    const stripChars = chars(strip.text);
    let position = 1;
    for (const hit of strip.hits) {
      if (hit.x > position) cv.put(7 + position, 1, stripChars.slice(position - 1, hit.x - 1).join(""), t.text, t.surface);
      const w = win(hit.id);
      let fg = t.text, bg = t.surface;
      if (w && w.mode === "minimized") fg = t.muted;
      if (w) {
        const [accent, foreground] = instanceAccent(t, w.accent);
        if (hit.id === state.focus) { fg = foreground; bg = accent; }
        else if (w.mode !== "minimized" && w.accent) fg = accent;
      }
      cv.put(7 + hit.x, 1, stripChars.slice(hit.x - 1, hit.x - 1 + hit.width).join(""), fg, bg);
      position = hit.x + hit.width;
      hits.push({ id: hit.id, x: hit.x + 7, width: hit.width });
    }
    if (!strip.hits.length) { const empty = truncate(" No applications open", room); cv.put(8, 1, empty, t.muted, t.surface); }
    let x = 8 + room;
    if (restore) {
      ["minimize", "fullscreen", "close"].forEach((action, i) => hits.push({ id: full.id, x: x + i * 3, width: 3, action }));
      cv.put(x, 1, restore, t.accent, t.surface); x += twidth(restore);
    }
    cv.put(x, 1, right, t.muted, t.surface);
    return hits;
  }

  // ---------------------------------------------------------------- window chrome
  function controls(w, rect) {
    const out = [];
    if (w.mode === "fullscreen" || rect.width < 5) return out;
    const actions = ["close"], labels = [" × "];
    if (rect.width >= 11) { actions.unshift(w.mode === "collapsed" ? "restore" : "fullscreen"); labels.unshift(w.mode === "collapsed" ? " ◇ " : " □ "); }
    if (rect.width >= 15) { actions.unshift("minimize"); labels.unshift(" − "); }
    let x = rect.x + rect.width - 1 - actions.length * 3;
    actions.forEach((action, i) => { out.push({ action, label: labels[i], x, y: rect.y, width: 3 }); x += 3; });
    return out;
  }
  function controlAt(w, rect, x, y) {
    if (y !== rect.y) return null;
    for (const c of controls(w, rect)) if (x >= c.x && x < c.x + c.width) return c.action;
    return null;
  }
  function edgeAt(rect, x, y) {
    if (!(x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height)) return "";
    let edge = "";
    if (x === rect.x) edge += "l"; else if (x === rect.x + rect.width - 1) edge += "r";
    if (y === rect.y) edge += "t"; else if (y === rect.y + rect.height - 1) edge += "b";
    return edge === "t" ? "move" : edge;
  }
  function interior(w, rect) {
    if (w.mode === "fullscreen" || rect.width < 3 || rect.height < 3) return rect;
    return { x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: rect.height - 2 };
  }
  function drawChrome(cv, w, rect, active, t) {
    const [accent] = instanceAccent(t, w.accent);
    const edge = active ? accent : t.border;
    const titleFg = active ? t.text : t.muted;
    const cs = controls(w, rect);
    const stop = cs.length ? cs[0].x : rect.x + rect.width - 1;
    const room = Math.max(0, stop - rect.x - 3);
    const title = truncate(displayTitle(w), room, "…");
    if (w.mode === "collapsed") cv.put(rect.x, rect.y, " ".repeat(rect.width), titleFg, t.surface, rect.width);
    else cv.put(rect.x, rect.y, "╭" + "─".repeat(Math.max(0, rect.width - 2)) + "╮", edge, t.surface, rect.width);
    if (room > 0) cv.put(rect.x + 2, rect.y, " " + title + " ", titleFg, t.surface, room + 1);
    for (const c of cs) cv.put(c.x, c.y, c.label, edge, t.surface, c.width);
    if (rect.height <= 1) return;
    for (let y = rect.y + 1; y <= rect.y + rect.height - 2; y++) { cv.put(rect.x, y, "│", edge, t.surface, 1); cv.put(rect.x + rect.width - 1, y, "│", edge, t.surface, 1); }
    cv.put(rect.x, rect.y + rect.height - 1, "╰" + "─".repeat(Math.max(0, rect.width - 2)) + "╯", edge, t.surface, rect.width);
  }

  // ---------------------------------------------------------------- dialog
  function drawDialog(cv, t) {
    const d = state.dialog;
    const width = Math.min(state.width - 4, Math.max(40, twidth(d.text) + 6));
    const height = d.kind === "text" ? 7 : 6;
    const x = Math.max(1, Math.floor((state.width - width) / 2) + 1), y = Math.max(2, Math.floor((state.height - height) / 2) + 1);
    cv.fill(x, y, width, height, t.text, t.surface);
    cv.put(x, y, "╭" + "─".repeat(width - 2) + "╮", t.accent, t.surface, width);
    for (let yy = y + 1; yy < y + height - 1; yy++) { cv.put(x, yy, "│", t.accent, t.surface, 1); cv.put(x + width - 1, yy, "│", t.accent, t.surface, 1); }
    cv.put(x, y + height - 1, "╰" + "─".repeat(width - 2) + "╯", t.accent, t.surface, width);
    cv.put(x + 2, y, " " + (d.kind === "text" ? "Rename" : "Confirm") + " ", t.text, t.surface);
    cv.put(x + 2, y + 2, truncate(d.text, width - 4, "…"), t.text, t.surface);
    let cursor = null;
    if (d.kind === "text") {
      cv.put(x + 2, y + 3, " ".repeat(width - 4), t.text, t.ground, width - 4);
      const shown = truncate(d.value, width - 5, "");
      cv.put(x + 2, y + 3, shown, t.text, t.ground);
      cursor = { x: x + 2 + twidth(shown), y: y + 3 };
    }
    const okLabel = " Enter " + d.ok + " ", cancel = " Esc Cancel ";
    cv.put(x + 2, y + height - 2, okLabel, selectionText(t), t.accent);
    cv.put(x + 2 + twidth(okLabel) + 1, y + height - 2, cancel, t.muted, t.surface);
    return cursor;
  }
  function dialogKey(e) {
    const d = state.dialog;
    if (e.key === "Escape") { state.dialog = null; return; }
    if (e.key === "Enter") {
      state.dialog = null;
      if (d.kind === "confirm") { if (d.target === "quit") quit(); else closeWindow(d.target, true); }
      else { const w = win(d.target); if (w) { w.label = d.value.trim(); setStatus("Renamed to " + displayTitle(w)); } }
      return;
    }
    if (d.kind === "text") {
      if (e.key === "Backspace") d.value = chars(d.value).slice(0, -1).join("");
      else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && twidth(d.value) < 40) d.value += e.key;
    }
  }

  // ---------------------------------------------------------------- applications
  const apps = {};

  // Terminal: a demo shell in the page.
  apps.terminal = {
    create() {
      return { lines: ["# demo shell inside the page, type help"], input: "", history: [], hist: -1, scroll: 0, exited: false, busy: null, cwd: "~/project" };
    },
    draw(app, w, h, t, focused) {
      const p = page(t, true); const cv = new Cells(w, h); cv.clear(p.fg, p.bg);
      const rows = app.lines.concat([ (app.busy ? "" : "bee $ " + app.input) ]);
      const capacity = h;
      const start = Math.max(0, rows.length - capacity - app.scroll);
      let cursor = null;
      for (let i = 0; i < capacity; i++) {
        const line = rows[start + i]; if (line == null) break;
        cv.put(1, 1 + i, line, p.fg, p.bg, w);
        if (start + i === rows.length - 1 && !app.busy && app.scroll === 0) cursor = { x: 1 + twidth(line), y: 1 + i };
      }
      return { cells: cv, cursor: focused ? cursor : null };
    },
    key(app, e) {
      if (app.busy) { if (e.ctrlKey && e.key.toLowerCase() === "c") { clearTimeout(app.busy); app.busy = null; app.lines.push("^C"); } return; }
      app.scroll = 0;
      if (e.ctrlKey && e.key.toLowerCase() === "c") { app.lines.push("bee $ " + app.input + "^C"); app.input = ""; return; }
      if (e.ctrlKey && e.key.toLowerCase() === "l") { app.lines = []; return; }
      if (e.ctrlKey && e.key.toLowerCase() === "u") { app.input = ""; return; }
      if (e.key === "Enter") { const cmd = app.input; app.lines.push("bee $ " + cmd); app.input = ""; if (cmd.trim()) { app.history.push(cmd); app.hist = -1; run(app, cmd.trim()); } return; }
      if (e.key === "Backspace") { app.input = chars(app.input).slice(0, -1).join(""); return; }
      if (e.key === "ArrowUp") { if (app.history.length) { app.hist = app.hist < 0 ? app.history.length - 1 : Math.max(0, app.hist - 1); app.input = app.history[app.hist]; } return; }
      if (e.key === "ArrowDown") { if (app.hist >= 0) { app.hist++; if (app.hist >= app.history.length) { app.hist = -1; app.input = ""; } else app.input = app.history[app.hist]; } return; }
      if (e.key === "Tab") { const names = Object.keys(COMMANDS).filter((c) => c.startsWith(app.input)); if (names.length === 1) app.input = names[0] + " "; return; }
      if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) app.input += e.key;
    },
    wheel(app, dir) { app.scroll = clamp(app.scroll - dir * 3, 0, Math.max(0, app.lines.length - 1)); },
    scrollable(app) { return app.lines.length + 1 > (app.height || 0) || app.scroll > 0; },
    mouse() {},
  };
  const FILES = {
    "README.md": ["# project", "", "A small service with a Makefile and tests.", "Run `make check` before opening a pull request."],
    "Makefile": ["check: lint test", "lint:\n\tgo vet ./...", "test:\n\tgo test ./..."],
    "main.go": ["package main", "", "func main() {", "\tserve(\":8080\")", "}"],
  };
  const COMMANDS = {
    help: (a) => out(a, ["help ls cat pwd echo date clear make history exit", "claude [-p prompt]   codex [prompt]   bee --version"]),
    ls: (a) => out(a, ["Makefile  README.md  docs/  main.go  src/  tests/"]),
    pwd: (a) => out(a, ["/home/you/project"]),
    whoami: (a) => out(a, ["you"]),
    date: (a) => out(a, [new Date().toString()]),
    uname: (a) => out(a, ["Linux bee 6.12.0 #1 SMP x86_64 GNU/Linux"]),
    clear: (a) => { a.lines = []; },
    history: (a) => out(a, a.history.map((h, i) => "  " + (i + 1) + "  " + h)),
    echo: (a, args) => out(a, [args.join(" ")]),
    cat: (a, args) => out(a, args.length ? [].concat(...args.map((f) => FILES[f] ? FILES[f].flatMap((l) => l.split("\n")) : ["cat: " + f + ": No such file"])) : ["cat: missing file"]),
    exit: (a) => { a.exited = true; out(a, ["exit"]); const w = state.windows.find((x) => x.app === a); if (w) setTimeout(() => { closeWindow(w.id, true); render(); }, 300); },
    bee: (a, args) => {
      if (args[0] === "--version") return out(a, ["bee 0.3.0-dev (linux/amd64)", "wippy runtime 0.9, application pack bee@0.3.0"]);
      if (args[0] === "update") return script(a, [[200, "bee update: checking the selected local pack"], [700, "bee update: application pack bee@0.3.0 is current"]]);
      out(a, ["bee: already inside Bee. Press F1 to open applications,", "     or run one of: bee claude, bee codex, bee agy"]);
    },
    claude: (a, args) => launch(a, "claude", args), codex: (a, args) => launch(a, "codex", args), agy: (a) => out(a, ["agy: not installed in this demo"]),
    make: (a, args) => {
      if (args[0] !== "check") return out(a, ["make: *** No rule to make target '" + (args[0] || "") + "'.  Stop."]);
      script(a, [[150, "go vet ./..."], [500, "go test ./..."], [700, "ok  \tproject/internal/api\t0.412s"], [400, "ok  \tproject/internal/store\t0.188s"], [300, "ok  \tproject\t0.021s"]]);
    },
  };
  function out(a, lines) { for (const l of lines) a.lines.push(l); }
  function script(a, steps) {
    let i = 0;
    const step = () => { if (i >= steps.length) { a.busy = null; render(); return; } const [ms, line] = steps[i++]; a.busy = setTimeout(() => { a.lines.push(line); render(); step(); }, ms); };
    a.busy = setTimeout(step, 0);
  }
  function launch(a, kind, args) {
    const p = args.indexOf("-p");
    const prompt = p >= 0 ? args.slice(p + 1).join(" ") : args.join(" ");
    out(a, ["bee: opening " + kind + " fullscreen"]);
    setTimeout(() => { openApp(kind, { prompt, fullscreen: true }); render(); }, 250);
  }
  function run(app, line) {
    const parts = line.match(/(?:[^\s"]+|"[^"]*")+/g).map((p) => p.replace(/^"|"$/g, ""));
    const cmd = COMMANDS[parts[0]];
    if (!cmd) return out(app, ["bash: " + parts[0] + ": command not found"]);
    cmd(app, parts.slice(1));
  }


  // Claude Code and Codex: scripted sessions in the real launch shape.
  const A = (fg, text) => ({ fg, text });
  const SESSIONS = {
    claude: {
      title: "Claude Code",
      header: (cwd) => [[A("accent", " ▐▛███▜▌"), A("text", "  Claude Code")], [A("accent", "▝▜█████▛▘"), A("muted", "  " + cwd)], []],
      prompt: "fix the failing test",
      run: () => [
        [300, [A("accent", "● "), A("text", "Running the tests first.")]],
        [200, []],
        [350, [A("accent", "● "), A("text", "Bash"), A("muted", "(go test ./...)")]],
        [500, [A("muted", "  ⎿  37 of 500 failing · TestFormatDuration and friends")]],
        [200, []],
        [350, [A("accent", "● "), A("text", "Read"), A("muted", "(internal/format.go)")]],
        [350, [A("muted", "  ⎿  Read 84 lines")]],
        [200, []],
        [900, { type: "show me the tests in a window while you work" }],
        [350, [A("accent", "● "), A("text", "Preparing a governed Bee app for that.")]],
        [200, []],
        [400, [A("accent", "● "), A("text", "Write"), A("muted", "(src/apps/test_watch/_index.yaml)")]],
        [400, [A("muted", "  ⎿  watcher process.lua · view · policy exec:test")]],
        [350, [A("accent", "● "), A("text", "freeze"), A("muted", " (Governance)(src/apps/test_watch)")]],
        [600, [A("muted", "  ⎿  reviewed overlay ready")]],
        [250, () => openTestWatch()],
        [200, []],
        [350, [A("accent", "● "), A("text", "Test Watch follows the tests. Codex can take the flaky ones.")]],
        [200, []],
        [350, [A("accent", "● "), A("text", "bee:thread_open"), A("muted", " (MCP)(agents, with: codex@desk)")]],
        [450, [A("muted", "  ⎿  codex joined · window opened on desk")]],
        [150, () => launchCodexFromClaude("build a workflow to inspect all tests for editorial comments")],
        [200, []],
        [350, [A("accent", "● "), A("text", "bee:thread_send"), A("muted", " (MCP)(agents)")]],
        [300, [A("muted", "  ⎿  build a workflow to inspect all tests for editorial comments")]],
        [200, []],
        [500, [A("accent", "● "), A("text", "Update"), A("muted", "(internal/format.go)")]],
        [350, [A("muted", "  ⎿  Updated 1 file  +3 −1")]],
        [200, []],
        [350, [A("accent", "● "), A("text", "Bash"), A("muted", "(go test ./...)")]],
        [100, () => testWatch("run")],
        [2200, [A("muted", "  ⎿  ok   500 passed  0.31s")]],
        [200, []],
        [350, [A("accent", "● "), A("text", "Fixed. Pushing.")]],
        [350, [A("accent", "● "), A("text", "Bash"), A("muted", "(git push origin main)")]],
        [600, [A("muted", "  ⎿  main is green")]],
        [200, []],
        [350, [A("accent", "● "), A("text", "bee:thread_wait"), A("muted", " (MCP)(agents)")]],
      ],
      again: () => [
        [500, [A("accent", "● "), A("text", "Looking at that.")]],
        [600, [A("accent", "● "), A("text", "Read"), A("muted", "(internal/format.go)")]],
        [500, [A("muted", "  ⎿  Read 86 lines")]],
        [700, [A("accent", "● "), A("text", "Update"), A("muted", "(internal/format.go)")]],
        [500, [A("muted", "  ⎿  Updated 1 file  +2 −0")]],
        [500, [A("accent", "● "), A("text", "Bash"), A("muted", "(go test ./...)")]],
        [800, [A("muted", "  ⎿  ok   project/internal  0.29s")]],
        [400, [A("accent", "● "), A("text", "Done.")]],
      ],
      user: (text) => [[A("muted", "> "), A("text", text)], []],
      box: true,
    },
    codex: {
      title: "Codex",
      header: (cwd) => [[A("accent", " ╭──────────────────────────╮")], [A("accent", " │ "), A("text", ">_ OpenAI Codex"), A("accent", "          │")], [A("accent", " │ "), A("muted", "model: gpt-5-codex"), A("accent", "       │")], [A("accent", " │ "), A("muted", "dir: " + cwd), A("accent", "           │")], [A("accent", " ╰──────────────────────────╯")], []],
      prompt: "build a workflow to inspect all tests for editorial comments",
      run: () => [
        [400, [A("accent", "codex")]],
        [150, [A("text", "Scanning test files for editorial comments.")]],
        [300, []],
        [600, [A("accent", "exec")]],
        [200, [A("muted", "$ rg -n \"// (FIXED|TODO|hack|previously)\" -g \"*_test.go\"")]],
        [800, [A("muted", "format_test.go:12  // FIXED: was flaky")]],
        [150, [A("muted", "store_test.go:44   // TODO remove this hack")]],
        [150, [A("muted", "list_test.go:9     // previously used a mock")]],
        [300, []],
        [900, [A("accent", "codex")]],
        [200, [A("text", "Writing a workflow that reruns this on every test change.")]],
        [300, []],
        [800, [A("accent", "apply_patch")]],
        [200, [A("muted", "*** Add File: apps/test_lint/app.lua")]],
        [200, [A("text", "+ workflow.on(\"tests.changed\", scan)")]],
        [300, []],
        [700, [A("accent", "tool freeze")]],
        [200, [A("muted", "apps/test_lint")]],
        [800, [A("muted", "reviewed overlay ready")]],
        [300, () => openTestLint()],
        [300, []],
        [500, [A("accent", "codex")]],
        [200, [A("text", "Test Lint is open. 3 comments to clean.")]],
        [300, []],
        [500, [A("accent", "tool bee.thread_reply")]],
        [200, [A("muted", "agents: Test Lint ready · 3 findings")]],
        [900, () => { claudeSay([A("muted", "  ⎿  codex@desk: Test Lint ready · 3 findings")]); }],
        [600, () => { claudeSay([A("accent", "● "), A("text", "Both apps are ready in this workspace.")]); claudeSay([A("muted", "  ⎿  say the word and I'll clean those comments")]); }],
      ],
      again: () => [
        [500, [A("accent", "codex")]],
        [200, [A("text", "On it.")]],
        [600, [A("accent", "exec")]],
        [200, [A("muted", "$ go test ./...")]],
        [900, [A("muted", "ok   project  0.22s")]],
        [400, [A("accent", "codex")]],
        [200, [A("text", "Done.")]],
      ],
      user: (text, from) => [[A("accent", from || "user")], [A("text", text)], []],
      box: false,
    },
  };
  function agentApp(kind) {
    const spec = SESSIONS[kind];
    return {
      create(options) {
        const app = { kind, lines: spec.header("~/project"), input: "", busy: null, exited: false, pending: (options && options.prompt) || spec.prompt, from: options && options.from, started: false, typing: "" };
        setTimeout(() => this.begin(app), 900);
        return app;
      },
      begin(app) {
        if (app.started) return; app.started = true;
        this.typeTurn(app, app.pending, () => this.play(app, spec.run(app.pending)));
      },
      play(app, steps) {
        let i = 0;
        const step = () => {
          if (i >= steps.length) { app.busy = null; render(); return; }
          const [ms, item] = steps[i++];
          app.busy = setTimeout(() => {
            if (typeof item === "function") { item(app); render(); step(); return; }
            if (item && item.type) { this.typeTurn(app, item.type, step); return; }
            app.lines.push(item); render(); step();
          }, ms);
        };
        step();
      },
      typeTurn(app, text, done) {
        let i = 0;
        const type = () => {
          if (i < text.length) { app.typing = text.slice(0, ++i); render(); app.busy = setTimeout(type, 28 + Math.random() * 40); return; }
          app.typing = ""; const last = app.lines[app.lines.length - 1]; if (last && last.length) app.lines.push([]);
          for (const l of spec.user(text, app.from)) app.lines.push(l); app.from = null; render(); done();
        };
        app.busy = setTimeout(type, 200);
      },
      draw(app, w, h, t, focused) {
        const p = page(t, true); const cv = new Cells(w, h); cv.clear(p.fg, p.bg);
        const color = (name) => (name === "accent" ? t.accent : name === "muted" ? t.muted : p.fg);
        const footer = spec.box ? 4 : 2;
        const capacity = Math.max(0, h - footer);
        const start = Math.max(0, app.lines.length - capacity);
        for (let i = 0; i < capacity; i++) {
          const line = app.lines[start + i]; if (!line) break;
          let x = 1;
          for (const seg of line) { cv.put(x, 1 + i, seg.text, color(seg.fg), p.bg, Math.max(0, w - x + 1)); x += twidth(seg.text); }
        }
        const text = app.typing || app.input;
        let cursor = null;
        if (spec.box) {
          cv.put(1, h - 2, "╭" + "─".repeat(Math.max(0, w - 2)) + "╮", t.border, p.bg, w);
          cv.put(1, h - 1, "│ > " + pad(truncate(text, w - 6, ""), w - 6) + " │", t.border, p.bg, w);
          cv.put(3, h - 1, "> ", t.accent, p.bg);
          cv.put(5, h - 1, truncate(text, w - 6, ""), p.fg, p.bg);
          cv.put(1, h, "╰" + "─".repeat(Math.max(0, w - 2)) + "╯", t.border, p.bg, w);
          cursor = { x: 5 + twidth(truncate(text, w - 6, "")), y: h - 1 };
        } else {
          cv.put(1, h, "› " + truncate(text, w - 3, ""), t.accent, p.bg, w);
          cv.put(3, h, truncate(text, w - 3, ""), p.fg, p.bg);
          cursor = { x: 3 + twidth(truncate(text, w - 3, "")), y: h };
        }
        return { cells: cv, cursor: focused && !app.busy ? cursor : null };
      },
      key(app, e) {
        if (e.ctrlKey && e.key.toLowerCase() === "c") {
          if (app.busy) { clearTimeout(app.busy); app.busy = null; app.typing = ""; app.lines.push([A("muted", "Interrupted")]); return; }
          const w = state.windows.find((x) => x.app === app); if (w) closeWindow(w.id, true); return;
        }
        if (app.busy) return;
        if (e.key === "Enter") {
          const text = app.input.trim(); app.input = ""; if (!text) return;
          if (text === "/exit" || text === "exit" || text === "/quit") { const w = state.windows.find((x) => x.app === app); if (w) closeWindow(w.id, true); return; }
          for (const l of spec.user(text)) app.lines.push(l);
          this.play(app, spec.again(text));
          return;
        }
        if (e.key === "Backspace") { app.input = chars(app.input).slice(0, -1).join(""); return; }
        if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) app.input += e.key;
      },
      wheel() {},
      mouse() {},
    };
  }
  apps.claude = agentApp("claude");
  apps.codex = agentApp("codex");


  // Test Watch: the application the agent authors mid-task.
  const TOTAL_TESTS = 500;
  const initialWatch = () => { const cells = new Array(TOTAL_TESTS).fill("pass"); for (let i = 0; i < 37; i++) cells[(i * 7919 + 13) % TOTAL_TESTS] = "fail"; return cells; };
  const watch = { cells: initialWatch(), run: 1, at: Date.now(), timer: null };
  apps.testwatch = {
    create() { return {}; },
    draw(app, w, h, t) {
      const cv = new Cells(w, h); cv.clear(t.text, t.surface);
      const mix = (a, b, k) => "#" + [0, 2, 4].map((i) => Math.round(parseInt(a.slice(1 + i, 3 + i), 16) * (1 - k) + parseInt(b.slice(1 + i, 3 + i), 16) * k).toString(16).padStart(2, "0")).join("");
      const g1 = instanceAccent(t, "green")[0], g2 = mix(g1, t.surface, 0.28), rose = instanceAccent(t, "rose")[0], dim = mix(t.muted, t.surface, 0.55);
      const failing = watch.cells.filter((c) => c === "fail").length, running = watch.cells.filter((c) => c === "run").length;
      const put = (y, text, fg) => cv.put(2, y, truncate(text, w - 2, "…"), fg, t.surface, w - 2);
      put(1, "TEST WATCH", t.accent);
      put(2, "go test ./...  ·  run " + watch.run + "  ·  " + TOTAL_TESTS + " tests", t.muted);
      const cols = Math.max(10, w - 2);
      const rows = Math.ceil(TOTAL_TESTS / (cols * 2));
      const color = (i) => (i >= TOTAL_TESTS ? t.surface : watch.cells[i] === "fail" ? rose : watch.cells[i] === "run" ? dim : ((i % cols) + Math.floor(i / cols)) % 2 ? g2 : g1);
      for (let r = 0; r < rows; r++) {
        if (4 + r > h - 3) break;
        for (let c = 0; c < cols; c++) { const top = r * 2 * cols + c, bottom = top + cols; cv.put(2 + c, 4 + r, "▀", color(top), color(bottom), 1); }
      }
      const ago = Math.max(0, Math.round((Date.now() - watch.at) / 1000));
      put(h - 1, running ? "running…  " + (TOTAL_TESTS - running) + " done" : failing ? failing + " failing" : "all " + TOTAL_TESTS + " passing", running ? t.muted : failing ? t.text : t.accent);
      put(h, "watching internal/  ·  " + ago + "s ago", t.muted);
      return { cells: cv };
    },
    key() {}, wheel() {}, mouse() {},
  };
  function openTestWatch() {
    if (!CATALOG.find((d) => d.id === "testwatch")) CATALOG.push({ id: "testwatch", title: "Test Watch", icon: "W", group: "Tools", role: "inspection" });
    if (state.windows.find((w) => w.def === "testwatch")) return;
    const keep = state.focus;
    const w = openApp("testwatch");
    w.accent = "green"; watch.at = Date.now();
    const a = area();
    place(w.id, { x: Math.round(a.width * 0.61), y: a.y + Math.round(a.height * 0.68), width: Math.round(a.width * 0.37), height: Math.max(9, a.height - Math.round(a.height * 0.68)) });
    setStatus("Test Watch ready in the workspace", 3500);
    if (keep) focusWindow(keep);
  }
  function testWatch(mode) {
    watch.at = Date.now();
    clearTimeout(watch.timer);
    if (mode === "run") {
      watch.cells = watch.cells.map(() => "run");
      let i = 0;
      const wave = () => {
        for (let k = 0; k < 40 && i < TOTAL_TESTS; k++, i++) watch.cells[i] = "pass";
        watch.at = Date.now(); render();
        if (i < TOTAL_TESTS) watch.timer = setTimeout(wave, 110); else { watch.run++; watch.timer = null; }
      };
      watch.timer = setTimeout(wave, 250);
    } else { watch.cells = watch.cells.map(() => "pass"); watch.run++; }
  }
  // Inbox: an approval filed by an agent, answered by you.
  const inbox = { who: "", what: "", state: "pending", at: 0 };
  apps.inbox = {
    create() { return {}; },
    draw(app, w, h, t) {
      const cv = new Cells(w, h); cv.clear(t.text, t.surface);
      const put = (y, text, fg) => cv.put(2, y, truncate(text, w - 2, "…"), fg, t.surface, w - 2);
      put(1, "INBOX", t.accent); cv.put(9, 1, "workspace · " + (inbox.state === "pending" ? "1 pending" : "0 pending"), t.muted, t.surface);
      const left = Math.max(0, Math.round((inbox.at + 15 * 60000 - Date.now()) / 60000));
      cv.put(2, 3, inbox.state === "pending" ? "●" : "✓", t.accent, t.surface, 1); cv.put(4, 3, truncate(inbox.what, w - 5, "…"), t.text, t.surface);
      put(4, "   " + inbox.who + "  ·  " + (inbox.state === "pending" ? left + " min left" : "approved · posted"), t.muted);
      if (inbox.state === "pending") { cv.put(2, h, " Enter Approve ", selectionText(t), t.accent); cv.put(18, h, " D Deny   Esc Later", t.muted, t.surface); }
      else put(h, "the waiting action fired", t.accent);
      return { cells: cv };
    },
    key(app, e) { if (e.key === "Enter" && inbox.state === "pending") approveInbox(); },
    wheel() {}, mouse() {},
  };
  function openInbox(who, what) {
    inbox.who = who; inbox.what = what; inbox.state = "pending"; inbox.at = Date.now();
    const keep = state.focus;
    let w = state.windows.find((x) => x.def === "inbox");
    if (!w) { w = openApp("inbox"); w.accent = "amber"; }
    const a = area();
    if (a.width >= 100) place(w.id, { x: Math.round(a.width * 0.59), y: a.y + 1, width: Math.round(a.width * 0.39), height: 7 }); else w.mode = "fullscreen";
    focusWindow(w.id);
    setStatus("Approval waiting in your inbox", 3000);
  }
  function approveInbox() {
    inbox.state = "approved";
    const w = state.windows.find((x) => x.def === "inbox");
    setStatus("Approved · the waiting action fired", 3000);
    setTimeout(() => { if (w) closeWindow(w.id, true); const c = state.windows.find((x) => x.def === "claude"); if (c) focusWindow(c.id); render(); }, 1800);
  }
  apps.testlint = {
    create() { return {}; },
    draw(app, w, h, t) {
      const cv = new Cells(w, h); cv.clear(t.text, t.surface);
      const put = (y, text, fg) => cv.put(2, y, truncate(text, w - 2, "…"), fg, t.surface, w - 2);
      put(1, "TEST LINT", t.accent);
      put(2, "editorial comments in *_test.go  ·  reruns on change", t.muted);
      [["format_test.go:12", "// FIXED: was flaky"], ["store_test.go:44", "// TODO remove this hack"], ["list_test.go:9", "// previously used a mock"]].forEach(([f, c], i) => {
        cv.put(2, 4 + i, pad(f, 20), t.text, t.surface, 20); cv.put(22, 4 + i, truncate(c, w - 23, "…"), t.muted, t.surface, w - 23);
      });
      put(h, "3 findings  ·  [ Rewrite all ]", t.accent);
      return { cells: cv };
    },
    key() {}, wheel() {}, mouse() {},
  };
  function openTestLint() {
    if (!CATALOG.find((d) => d.id === "testlint")) CATALOG.push({ id: "testlint", title: "Test Lint", icon: "L", group: "Tools", role: "inspection" });
    if (state.windows.find((w) => w.def === "testlint")) return;
    const keep = state.focus;
    const w = openApp("testlint");
    w.accent = "rose";
    const a = area();
    if (a.width >= 100) place(w.id, { x: Math.round(a.width * 0.57), y: a.y + Math.round(a.height * 0.44), width: Math.round(a.width * 0.41), height: Math.max(9, Math.round(a.height * 0.23)) });
    else w.mode = "fullscreen";
    setStatus("Test Lint ready for review", 3500);
    if (keep && a.width >= 100) focusWindow(keep);
  }


  // Settings: appearance cards, ported from settings/view.lua.
  apps.settings = {
    create() { return { pane: "theme", index: 1, offset: 0, message: "", hits: [] }; },
    grid(width, height) {
      const columns = Math.max(1, Math.min(3, Math.floor((width - 2) / 24)));
      const rows = Math.max(0, Math.floor((height - 6) / 6));
      return { columns, rows, capacity: columns * rows, card_width: Math.max(1, Math.floor((width - 2 - (columns - 1) * 2) / columns)) };
    },
    offsetFor(index, offset, grid, count, reveal) {
      if (!grid.capacity) return 0;
      const last = Math.max(0, (Math.ceil(count / grid.columns) - grid.rows) * grid.columns);
      let value = clamp(Math.floor(offset / grid.columns) * grid.columns, 0, last);
      if (reveal) {
        if (index <= value) value = Math.floor((index - 1) / grid.columns) * grid.columns;
        if (index > value + grid.capacity) value = (Math.floor((index - 1) / grid.columns) - grid.rows + 1) * grid.columns;
      }
      return clamp(value, 0, last);
    },
    count(pane) { return pane === "taskbar" ? 2 : pane === "theme" ? THEMES.length : BACKGROUNDS.length; },
    current(app) { const p = state.prefs; return app.pane === "taskbar" ? (p.taskbar === "icons" ? 2 : 1) : app.pane === "theme" ? THEMES.findIndex((t) => t.id === p.theme) + 1 : BACKGROUNDS.indexOf(p.background) + 1; },
    select(app, index) {
      const p = state.prefs;
      if (app.pane === "taskbar") p.taskbar = index === 2 ? "icons" : "labels";
      else if (app.pane === "theme") p.theme = THEMES[index - 1].id;
      else p.background = BACKGROUNDS[index - 1];
      app.index = index; app.message = "Saved";
      applyPageTheme(); if (sceneCanvases.ready) paintScenes();
    },
    draw(app, width, height, t) {
      const prefs = state.prefs; const grid = this.grid(width, height);
      const count = this.count(app.pane);
      app.offset = this.offsetFor(app.index, app.offset, grid, count, true);
      const cv = new Cells(width, height); cv.clear(t.text, t.surface);
      const hits = [];
      cv.put(2, 1, "BEE SETTINGS", t.text, t.surface, width - 2);
      let tabX = 2;
      for (const kind of ["theme", "background", "taskbar"]) {
        let text = kind === "theme" ? " Themes " : kind === "background" ? " Backgrounds " : " Tabs ";
        if (width < 26) text = kind === "theme" ? " Theme " : kind === "background" ? " BG " : " Tabs ";
        const size = clamp(twidth(text), 0, width - tabX);
        const selected = app.pane === kind;
        cv.put(tabX, 2, text, selected ? selectionText(t) : t.muted, selected ? t.accent : t.surface, size);
        if (size >= 3) hits.push({ kind, index: 0, x: tabX, y: 2, width: size, height: 1 });
        tabX += size + 1;
      }
      if (!grid.capacity || width < 12) {
        const label = app.pane === "taskbar" ? (prefs.taskbar === "icons" ? "Icons" : "Labels") : app.pane === "theme" ? theme(prefs.theme).title : prefs.background;
        cv.put(2, 4, " ‹ ", t.accent, t.surface, 3); cv.put(6, 4, truncate(label, width - 11, "…"), t.text, t.surface); cv.put(width - 4, 4, " › ", t.accent, t.surface, 3);
        hits.push({ kind: "step", index: -1, x: 2, y: 4, width: 3, height: 1 }, { kind: "step", index: 1, x: width - 4, y: 4, width: 3, height: 1 });
        app.hits = hits; return { cells: cv };
      }
      for (let slot = 1; slot <= grid.capacity; slot++) {
        const index = app.offset + slot; if (index > count) break;
        const x = 2 + ((slot - 1) % grid.columns) * (grid.card_width + 2);
        const y = 4 + Math.floor((slot - 1) / grid.columns) * 6;
        const id = app.pane === "taskbar" ? (index === 1 ? "labels" : "icons") : app.pane === "theme" ? THEMES[index - 1].id : BACKGROUNDS[index - 1];
        const title = app.pane === "theme" ? THEMES[index - 1].title : id[0].toUpperCase() + id.slice(1);
        const selected = index === this.current(app);
        const edge = selected ? t.accent : t.border;
        const inside = grid.card_width - 2;
        cv.put(x, y, "╭" + "─".repeat(inside) + "╮", edge, t.surface, grid.card_width);
        for (let r = 1; r <= 3; r++) cv.put(x, y + r, "│" + " ".repeat(inside) + "│", edge, t.surface, grid.card_width);
        cv.put(x, y + 4, "╰" + "─".repeat(inside) + "╯", edge, t.surface, grid.card_width);
        const label = " " + (selected ? "✓ " : "") + title + " ";
        cv.put(x + 1, y, truncate(label, inside, "…"), selected ? t.accent : t.text, t.surface, inside);
        if (app.pane === "taskbar") cv.put(x + 1, y + 2, truncate(index === 1 ? " Terminal  Settings " : " >_  S  P ", inside, "…"), t.text, t.surface, inside);
        else if (app.pane === "background") { for (let r = 1; r <= 3; r++) cv.put(x + 1, y + r, backgroundRow(id, inside, r, 3), t.pattern, t.ground, inside); }
        else {
          const c = THEMES[index - 1];
          cv.put(x + 1, y + 1, " ".repeat(inside), c.text, c.ground, inside);
          cv.put(x + 1, y + 2, "  Aa   Bee" + " ".repeat(inside), c.text, c.surface, inside);
          const band = Math.max(1, Math.floor(inside / 3));
          cv.put(x + 1, y + 3, " ".repeat(inside), c.text, c.accent, inside);
          cv.put(x + 1 + band, y + 3, " ".repeat(band), c.text, c.border, band);
          cv.put(x + 1 + band * 2, y + 3, " ".repeat(inside - band * 2), c.text, c.muted, inside - band * 2);
        }
        if (index === app.index && !selected) cv.put(x + 1, y + 4, "─".repeat(Math.min(inside, 3)), t.accent, t.surface, inside);
        hits.push({ kind: "select", index, x, y, width: grid.card_width, height: 5 });
      }
      const last = Math.min(count, app.offset + grid.capacity);
      const range = (app.offset + 1) + "–" + last + "/" + count;
      let status = "Theme: " + theme(prefs.theme).title + "  Background: " + prefs.background;
      if (width < 48) status = app.pane === "theme" ? "Theme: " + theme(prefs.theme).title : "Background: " + prefs.background;
      if (app.pane === "taskbar") status = "Tabs: " + (prefs.taskbar === "icons" ? "Icons" : "Labels");
      if (app.message) status = app.message;
      cv.put(2, height - 2, status, t.text, t.surface, width - 2);
      let pager = " ‹ " + range + " › ";
      if (twidth(pager) > width - 2) pager = " ‹  › ";
      const pagerX = width - twidth(pager);
      cv.put(2, height - 1, width >= 60 ? "Arrows Choose  Tab Switch  Wheel Browse" : "Tab Switch", t.muted, t.surface, Math.max(0, pagerX - 3));
      cv.put(pagerX, height - 1, pager, t.muted, t.surface, twidth(pager));
      if (app.offset > 0) { cv.put(pagerX, height - 1, " ‹ ", t.accent, t.surface, 3); hits.push({ kind: "page", index: -1, x: pagerX, y: height - 1, width: 3, height: 1 }); }
      if (last < count) { cv.put(width - 3, height - 1, " › ", t.accent, t.surface, 3); hits.push({ kind: "page", index: 1, x: width - 3, y: height - 1, width: 3, height: 1 }); }
      app.hits = hits; app.grid = grid;
      return { cells: cv };
    },
    key(app, e) {
      const count = this.count(app.pane); const cols = app.grid ? app.grid.columns : 1;
      app.message = "";
      const panes = ["theme", "background", "taskbar"];
      if (e.key === "Tab") { app.pane = panes[(panes.indexOf(app.pane) + (e.shiftKey ? 2 : 1)) % 3]; app.index = this.current(app); app.offset = 0; return; }
      if (e.key === "ArrowRight") app.index = Math.min(count, app.index + 1);
      else if (e.key === "ArrowLeft") app.index = Math.max(1, app.index - 1);
      else if (e.key === "ArrowDown") app.index = Math.min(count, app.index + cols);
      else if (e.key === "ArrowUp") app.index = Math.max(1, app.index - cols);
      else if (e.key === "Enter" || e.key === " ") this.select(app, app.index);
      else if (e.key === "Home") app.index = 1;
      else if (e.key === "End") app.index = count;
    },
    wheel(app, dir) { const count = this.count(app.pane); if (!app.grid) return; app.offset = this.offsetFor(app.index, app.offset + dir * app.grid.columns, app.grid, count, false); app.index = clamp(app.index, app.offset + 1, Math.min(count, app.offset + app.grid.capacity)); },
    scrollable(app) { return !!app.grid && this.count(app.pane) > app.grid.capacity; },
    mouse(app, x, y, button, action) {
      if (action !== "press" || button !== 0) return;
      const hit = app.hits.find((h) => x >= h.x && x < h.x + h.width && y >= h.y && y < h.y + h.height);
      if (!hit) return;
      app.message = "";
      if (hit.kind === "select") this.select(app, hit.index);
      else if (hit.kind === "page") this.wheel(app, hit.index * (app.grid ? app.grid.rows : 1));
      else if (hit.kind === "step") { const count = this.count(app.pane); this.select(app, ((this.current(app) - 1 + hit.index + count) % count) + 1); }
      else { app.pane = hit.kind; app.index = this.current(app); app.offset = 0; }
    },
  };

  // Process Manager: measured samples come from the simulator itself.
  const metrics = { heap: [], rate: [], queue: [], gc: 3, t0: Date.now() };
  function sample() {
    const n = state.windows.length;
    const last = metrics.heap[metrics.heap.length - 1] || 14;
    const collect = last > 22 + n * 1.5 || Math.random() < 0.04;
    const heap = collect ? 11.5 + n * 0.8 + Math.random() : last + 0.6 + Math.random() * 0.9;
    if (collect) metrics.gc++;
    const rate = 40 + n * 25 + Math.random() * 30 + (Math.random() < 0.1 ? 120 : 0);
    const queue = Math.random() < 0.85 ? 0 : Math.floor(Math.random() * 3) + 1;
    metrics.heap.push(heap); metrics.rate.push(rate); metrics.queue.push(queue);
    for (const k of ["heap", "rate", "queue"]) if (metrics[k].length > 120) metrics[k].shift();
  }
  const BARS = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"];
  function spark(values, width) {
    let peak = 1; const first = Math.max(0, values.length - width);
    for (let i = first; i < values.length; i++) peak = Math.max(peak, values[i]);
    let s = " ".repeat(Math.max(0, width - values.length));
    for (let i = first; i < values.length; i++) { const v = values[i]; s += v < 0 ? "·" : BARS[clamp(Math.ceil((v / peak) * 8), 1, 8) - 1]; }
    return s;
  }
  const num = (v) => (v == null || v < 0 ? "—" : String(Math.round(v)));
  const CORE = [
    ["wp-1", "bee.workspace:main"], ["wp-2", "bee.session:main"], ["wp-3", "bee.applications:broker"], ["wp-4", "bee.terminal:presenter"], ["wp-5", "bee.threads:local"], ["wp-6", "bee.storage:workspace_db"],
  ];
  const SERVICES = [["bee.host:supervisor", "running", 0], ["bee.threads:local", "running", 0], ["bee.workspace.db:main", "running", 0], ["bee.terminal:display", "running", 1], ["wippy.hub:client", "idle", 0]];
  apps.processes = {
    create() { return { selected: "wp-1", offset: 0, paused: false, services: false, bySteps: false, status: "", confirming: false, steps: {} }; },
    rows(app) {
      if (app.services) return SERVICES.map(([id, st, r]) => ({ pid: id, source: id, state: st, steps: r }));
      const rows = CORE.map(([pid, src], i) => ({ pid, source: src, state: "running", steps: this.stepsFor(app, pid, 900 + i * 210) }));
      for (const w of state.windows) rows.push({ pid: "app-" + w.id, source: "bee." + w.def + ":app", state: w.mode === "minimized" ? "detached" : "running", steps: this.stepsFor(app, "app-" + w.id, 120) });
      if (app.bySteps) rows.sort((a, b) => b.steps - a.steps); else rows.sort((a, b) => a.source.localeCompare(b.source));
      return rows;
    },
    stepsFor(app, pid, base) { if (!(pid in app.steps)) app.steps[pid] = base; if (!app.paused) app.steps[pid] += Math.random() < 0.6 ? Math.floor(Math.random() * 4) : 0; return app.steps[pid]; },
    draw(app, width, height, t) {
      const cv = new Cells(width, height); cv.clear(t.text, t.surface);
      const put = (x, y, text, size, fg, bg) => { if (y >= 1 && y <= height && size > 0) cv.put(x, y, text, fg || t.text, bg || t.surface, size); };
      const rows = this.rows(app); app.cached = rows;
      const heap = metrics.heap[metrics.heap.length - 1], rate = metrics.rate[metrics.rate.length - 1], queue = metrics.queue[metrics.queue.length - 1];
      put(2, 1, " Processes ", 11, app.services ? t.muted : selectionText(t), app.services ? t.surface : t.accent);
      if (width >= 26) put(14, 1, " Services ", 10, app.services ? selectionText(t) : t.muted, app.services ? t.accent : t.surface);
      if (height >= 13 && width >= 48) put(2, 2, (app.paused ? "Paused" : "Live · 1s") + "  ·  " + rows.length + (app.services ? " services" : " processes"), width - 2, t.muted);
      if (width >= 38) put(width - 10, 1, app.paused ? " Resume " : " Pause ", 9, t.accent);
      let first = 4;
      if (width >= 48 && height >= 13) {
        const col = Math.floor((width - 4) / 3);
        const metric = (i, title, value, values) => { const x = 2 + (i - 1) * (col + 1); put(x, 3, title, col, t.muted); put(x, 4, value, col); put(x, 5, spark(values, col), col, t.accent); };
        metric(1, "Heap", heap ? heap.toFixed(1) + " MiB" : "—", metrics.heap);
        metric(2, "Scheduler", num(rate) + " steps/s", metrics.rate);
        metric(3, "Run queue", num(queue), metrics.queue);
        put(2, 7, (38 + state.windows.length * 3) + " goroutines · " + metrics.gc + " GC · " + (62.3 + state.windows.length * 2.1).toFixed(1) + " MiB reserved", width - 2, t.muted);
        first = 10;
      } else put(2, 2, "Heap " + (heap ? heap.toFixed(1) + "M" : "—") + "  Queue " + num(queue), width - 2, t.muted);
      const capacity = Math.max(0, height - first - 2);
      app.offset = clamp(app.offset, 0, Math.max(0, rows.length - capacity)); app.first = first; app.capacity = capacity;
      put(2, first - 1, app.services ? "SERVICE" : "PROCESS", Math.max(0, width - 22), t.muted);
      if (width >= 38) put(width - 21, first - 1, app.services ? "STATE      RESTARTS" : "STATE         STEPS", 21, t.muted);
      for (let r = 1; r <= capacity; r++) {
        const item = rows[app.offset + r - 1]; if (!item) continue;
        const active = item.pid === app.selected;
        const fg = active ? selectionText(t) : t.text, bg = active ? t.accent : t.surface;
        put(1, first + r - 1, " ".repeat(width), width, fg, bg);
        const room = Math.max(1, width >= 38 ? width - 24 : width - 2);
        put(2, first + r - 1, truncate(item.source || item.pid, room, "…"), room, fg, bg);
        if (width >= 38) { put(width - 21, first + r - 1, truncate(item.state, 10, "…"), 10, fg, bg); put(width - 10, first + r - 1, String(item.steps).padStart(10), 10, fg, bg); }
      }
      const sel = rows.find((r) => r.pid === app.selected);
      put(2, height - 1, sel ? sel.pid : "", width - 2, t.muted);
      let footer = app.status;
      if (app.confirming) footer = "End selected app? Enter / Esc";
      if (!footer) {
        put(2, height, app.bySteps ? (app.services ? " Sort: restarts " : " Sort: steps ") : " Sort: name ", Math.max(0, width - 13), t.accent);
        if (!app.services) put(Math.max(1, width - 10), height, " End app ", 9, t.accent);
      } else put(2, height, footer, width - 2, app.confirming ? t.accent : t.muted);
      return { cells: cv };
    },
    endSelected(app) {
      const rows = app.cached || []; const i = rows.findIndex((r) => r.pid === app.selected); const item = rows[i];
      if (!item) return;
      if (item.pid.startsWith("app-")) { closeWindow(item.pid.slice(4), true); app.status = "Ended " + item.source; }
      else app.status = "Denied: " + item.source + " is a protected core process";
      app.selected = (rows[i + 1] || rows[0] || {}).pid || "";
      setTimeout(() => { app.status = ""; render(); }, 2500);
    },
    key(app, e) {
      const rows = app.cached || []; const i = rows.findIndex((r) => r.pid === app.selected);
      if (app.confirming) { if (e.key === "Enter") { app.confirming = false; this.endSelected(app); } else if (e.key === "Escape") app.confirming = false; return; }
      if (e.key === "ArrowDown") app.selected = (rows[Math.min(rows.length - 1, i + 1)] || {}).pid;
      else if (e.key === "ArrowUp") app.selected = (rows[Math.max(0, i - 1)] || {}).pid;
      else if (e.key === "Tab") { app.services = !app.services; app.selected = ""; }
      else if (e.key === " " || e.key.toLowerCase() === "p") app.paused = !app.paused;
      else if (e.key.toLowerCase() === "s") app.bySteps = !app.bySteps;
      else if (e.key === "Delete" || e.key.toLowerCase() === "e") { if (!app.services && app.selected) app.confirming = true; }
      if (app.cached) { const j = rows.findIndex((r) => r.pid === app.selected); if (j >= 0 && app.capacity) app.offset = clamp(app.offset, j - app.capacity + 1, j); }
    },
    wheel(app, dir) { app.offset = Math.max(0, app.offset + dir); },
    scrollable(app) { return (app.cached || []).length > (app.capacity || 0); },
    mouse(app, x, y, button, action, w) {
      if (action !== "press" || button !== 0) return;
      const width = w;
      if (y === 1) {
        if (x >= 2 && x < 13) { app.services = false; app.selected = ""; }
        else if (width >= 26 && x >= 14 && x < 24) { app.services = true; app.selected = ""; }
        else if (width >= 38 && x >= width - 10) app.paused = !app.paused;
        return;
      }
      if (app.first && y >= app.first && y < app.first + app.capacity) { const item = (app.cached || [])[app.offset + y - app.first]; if (item) app.selected = item.pid; return; }
      if (y === app.lastRow()) {
        if (app.confirming) return;
        if (x < 16) app.bySteps = !app.bySteps; else if (!app.services && x >= width - 10 && app.selected) app.confirming = true;
      }
    },
  };
  apps.processes.create = ((orig) => function () { const a = orig(); a.lastRow = () => a.height; return a; })(apps.processes.create);


  // ---------------------------------------------------------------- render
  const canvas = document.getElementById("sim");
  const ctx = canvas.getContext("2d");
  let cw = 9, chh = 19, fontSize = 15, dpr = 1;
  const FONT = '"IBM Plex Mono", "DejaVu Sans Mono", Menlo, Consolas, monospace';

  function measure() {
    dpr = Math.min(2, window.devicePixelRatio || 1);
    const shell = canvas.parentElement;
    const shellWidth = shell.clientWidth;
    const foot = shell.querySelector(".sim-foot");
    const avail = Math.max(240, shell.clientHeight - (foot ? foot.offsetHeight : 0));
    fontSize = shellWidth < 560 ? 12 : shellWidth < 900 ? 14 : 15;
    ctx.font = fontSize + "px " + FONT;
    cw = Math.ceil(ctx.measureText("M".repeat(20)).width / 20 * 100) / 100;
    chh = Math.round(fontSize * 1.3);
    state.width = Math.max(40, Math.floor(shellWidth / cw));
    state.height = Math.max(12, Math.floor(avail / chh));
    canvas.width = Math.round(state.width * cw * dpr); canvas.height = Math.round(state.height * chh * dpr);
    canvas.style.width = Math.round(state.width * cw) + "px"; canvas.style.height = state.height * chh + "px"; canvas.style.flex = "none";
    for (const w of state.windows) place(w.id, w.bounds);
    document.getElementById("cols").textContent = state.width; document.getElementById("rows").textContent = state.height;
  }

  function compose() {
    const t = theme(state.prefs.theme);
    const cv = new Cells(state.width, state.height);
    cv.clear(t.text, t.ground);
    for (let y = 1; y <= state.height; y++) cv.put(1, y, backgroundRow(state.prefs.background, state.width, y, state.height), t.pattern, t.ground, state.width);
    let cursor = null;
    const vis = visible();
    if (!vis.length || state.booting) drawWelcome(cv, t, state.booting);
    if (!state.booting) for (const w of vis) {
      const rect = bounds(w); const body = interior(w, rect);
      cv.fill(rect.x, rect.y, rect.width, rect.height, t.border, t.surface);
      if (w.mode === "collapsed") { drawChrome(cv, w, rect, w.id === state.focus, t); continue; }
      const focused = w.id === state.focus && !state.menu && !state.dialog;
      const content = apps[w.def].draw(w.app, body.width, body.height, t, focused);
      w.app.height = body.height; w.app.width = body.width;
      cv.blit(content.cells, body.x, body.y, body.width, body.height);
      if (focused && content.cursor && !state.capture) cursor = { x: body.x + content.cursor.x - 1, y: body.y + content.cursor.y - 1 };
      if (body.x !== rect.x) drawChrome(cv, w, rect, w.id === state.focus, t);
    }
    state.barHits = state.height >= 3 ? drawBar(cv, t) : [];
    if (state.menu) { drawMenu(cv, t); cursor = null; }
    if (state.dialog) cursor = drawDialog(cv, t);
    return { cv, cursor, t };
  }
  function drawWelcome(cv, t, starting) {
    let lines = ["    ╭──╮ ╭──╮    ", "    ╰──╲ ╱──╯    ", " ╭──────┴─────╮  ", "◂│ ██  ██  •  │  ", " ╰────────────╯  ", "       ╲ ╲       "];
    if (state.width < 24 || state.height < 14) lines = [];
    if (starting && state.height >= 5) lines = lines.concat(["", "Starting…"]);
    const top = Math.max(2, Math.floor((state.height - lines.length) / 2));
    lines.forEach((text, i) => { const y = top + i; if (y < state.height) { const x = Math.max(1, Math.floor((state.width - twidth(text)) / 2 + 1)); cv.put(x, y, text, starting ? t.accent : t.border, t.ground); } });
  }
  const TL = [0, 0, 0.5, 0.5], TR = [0.5, 0, 0.5, 0.5], BL = [0, 0.5, 0.5, 0.5], BR = [0.5, 0.5, 0.5, 0.5];
  const QUADS = { "█": [[0, 0, 1, 1]], "▀": [[0, 0, 1, 0.5]], "▄": [[0, 0.5, 1, 0.5]], "▌": [[0, 0, 0.5, 1]], "▐": [[0.5, 0, 0.5, 1]],
    "▘": [TL], "▝": [TR], "▖": [BL], "▗": [BR], "▛": [TL, TR, BL], "▜": [TL, TR, BR], "▙": [TL, BL, BR], "▟": [TR, BL, BR], "▚": [TL, BR], "▞": [TR, BL] };
  const BAR_FRACTION = { "▁": 1 / 8, "▂": 2 / 8, "▃": 3 / 8, "▅": 5 / 8, "▆": 6 / 8, "▇": 7 / 8 };
  QUADS["░"] = null;
  let blinkOn = true;
  function paint(target, cv, t, metrics_, cursor) {
    const { ctx: c, cw: w, chh: hh, fontSize: fs, dpr: d } = metrics_;
    c.setTransform(d, 0, 0, d, 0, 0);
    c.fillStyle = t.ground; c.fillRect(0, 0, target.width, target.height);
    c.font = fs + "px " + FONT; c.textBaseline = "middle";
    const W = cv.w;
    for (let y = 0; y < cv.h; y++) {
      let x = 0;
      while (x < W) {
        const i = y * W + x; const bg = cv.bg[i]; let run = 1;
        while (x + run < W && cv.bg[i + run] === bg) run++;
        if (bg !== t.ground) { c.fillStyle = bg; c.fillRect(x * w, y * hh, run * w + 0.5, hh + 0.5); }
        x += run;
      }
    }
    for (let y = 0; y < cv.h; y++) for (let x = 0; x < W; x++) {
      const i = y * W + x; const ch = cv.ch[i]; if (ch === " ") continue;
      const q = QUADS[ch];
      if (q) { c.fillStyle = cv.fg[i]; for (const [qx, qy, qw, qh] of q) c.fillRect(x * w + qx * w, y * hh + qy * hh, qw * w + 0.5, qh * hh + 0.5); continue; }
      const bar = BAR_FRACTION[ch];
      if (bar) { c.fillStyle = cv.fg[i]; c.fillRect(x * w, y * hh + (1 - bar) * hh, w + 0.5, bar * hh + 0.5); continue; }
      c.fillStyle = cv.fg[i]; c.fillText(ch, x * w, y * hh + hh / 2 + 0.5);
    }
    if (cursor) {
      const i = (cursor.y - 1) * W + (cursor.x - 1);
      c.fillStyle = cv.fg[i] || t.text; c.fillRect((cursor.x - 1) * w, (cursor.y - 1) * hh, w, hh);
      const ch = cv.ch[i]; if (ch && ch !== " ") { c.fillStyle = cv.bg[i]; c.fillText(ch, (cursor.x - 1) * w, (cursor.y - 1) * hh + hh / 2 + 0.5); }
    }
  }
  function render() {
    const { cv, cursor, t } = compose();
    paint(canvas, cv, t, { ctx, cw, chh, fontSize, dpr }, cursor && blinkOn && document.activeElement === canvas ? cursor : null);
    document.getElementById("msg").textContent = Date.now() < state.statusUntil ? state.status : "";
  }

  // ---------------------------------------------------------------- input
  function keyName(e) { return e.key; }
  canvas.addEventListener("keydown", (e) => {
    const handled = ["F1", "F11", "F12", "Tab", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PageUp", "PageDown", "Home", "End", " ", "Backspace", "Escape", "Enter"];
    if (e.key === "Tab" && !e.altKey && !state.menu && !state.dialog && !state.focus) return;
    if (handled.includes(e.key) || (e.altKey && e.key === "F9") || (e.ctrlKey && ["n", "q", "w", "l", "u", "c"].includes(e.key.toLowerCase()))) e.preventDefault();
    if (e.key === "Alt" || e.key === "Control" || e.key === "Shift" || e.key === "Meta") return;
    handleKey(e); render();
  });
  function handleKey(e) {
    if (state.booting) return;
    if (state.dialog) return dialogKey(e);
    if (state.menu) return menuKey(e);
    const k = e.key.toLowerCase();
    if (e.key === "F1") { state.menu = { kind: null, selected: 1, offset: 0, path: [] }; return; }
    if (e.ctrlKey && k === "n") { state.menu = { kind: null, selected: 1, offset: 0, path: [], initial: true }; return; }
    if (e.ctrlKey && k === "q") { state.dialog = { kind: "confirm", text: "Quit Bee? Running shells will end.", ok: "Quit", target: "quit" }; return; }
    if (e.altKey && e.key === "Tab") return altTab();
    if (e.key === "F12") return boot();
    if (state.focus) {
      const w = win(state.focus);
      if (e.key === "F11") return windowAction(w.id, "fullscreen");
      if (e.altKey && e.key === "F9") return windowAction(w.id, "minimize");
      if (e.ctrlKey && k === "w") return closeWindow(w.id);
      if (w.mode !== "minimized" && w.mode !== "collapsed") apps[w.def].key(w.app, e);
    } else if (e.key === "Enter" || e.key === " ") state.menu = { kind: null, selected: 1, offset: 0, path: [] };
  }
  function syntheticKey(name) {
    const map = { f1: { key: "F1" }, alttab: { key: "Tab", altKey: true }, f11: { key: "F11" }, altf9: { key: "F9", altKey: true }, ctrlw: { key: "w", ctrlKey: true }, f12: { key: "F12" } };
    const e = Object.assign({ key: "", altKey: false, ctrlKey: false, shiftKey: false, metaKey: false }, map[name]);
    canvas.focus({ preventScroll: true }); handleKey(e); render();
  }
  document.querySelectorAll(".sim-foot .btn").forEach((b) => b.addEventListener("click", () => syntheticKey(b.dataset.key)));
  document.querySelectorAll("[data-open]").forEach((b) => b.addEventListener("click", () => {
    openApp(b.dataset.open); render();
    document.getElementById("try").scrollIntoView({ behavior: "smooth", block: "start" });
    canvas.focus({ preventScroll: true });
  }));

  function cellAt(e) {
    const r = canvas.getBoundingClientRect();
    return { x: clamp(Math.floor((e.clientX - r.left) / (r.width / state.width)) + 1, 1, state.width), y: clamp(Math.floor((e.clientY - r.top) / (r.height / state.height)) + 1, 1, state.height) };
  }
  function windowAt(x, y) {
    const vis = visible();
    for (let i = vis.length - 1; i >= 0; i--) { const w = vis[i]; const rect = bounds(w); if (x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height) return w; }
    return null;
  }
  function routePointer(x, y, button, action, fromMenu) {
    if (state.booting || state.dialog) return;
    if (state.menu) return menuMouse(x, y, button, action);
    if (y === 1) {
      if (action !== "press") return;
      if (x <= 7) { if (button === 0) state.menu = { kind: null, selected: 1, offset: 0, path: [] }; return; }
      const hit = (state.barHits || []).find((h) => x >= h.x && x < h.x + h.width);
      if (!hit) return;
      if (button === 2) { state.menu = { kind: "window", target: hit.id, selected: 1, offset: 0, path: [], x, y: 2 }; return; }
      if (hit.action) return windowAction(hit.id, hit.action);
      const w = win(hit.id);
      if (w.id === state.focus && w.mode !== "minimized") windowAction(hit.id, "minimize"); else focusWindow(hit.id);
      return;
    }
    const w = windowAt(x, y);
    if (!w) {
      if (action === "press" && button === 2) state.menu = { kind: "desktop", selected: 1, offset: 0, path: [], x, y };
      return;
    }
    const rect = bounds(w);
    if (action === "press") {
      focusWindow(w.id);
      const control = controlAt(w, rect, x, y);
      if (control && button === 0) return windowAction(w.id, control);
      const edge = w.mode === "fullscreen" ? "" : edgeAt(rect, x, y);
      if (edge && button === 2) { state.menu = { kind: "window", target: w.id, selected: 1, offset: 0, path: [], x, y }; return; }
      if (edge && button === 0) {
        if (w.mode === "collapsed" && edge !== "move") return;
        state.capture = { id: w.id, x, y, bounds: Object.assign({}, w.bounds), edge }; return;
      }
    }
    const body = interior(w, rect);
    if (w.mode !== "collapsed" && x >= body.x && x < body.x + body.width && y >= body.y && y < body.y + body.height) {
      if (action === "press" && button === 2) { state.menu = { kind: "window", target: w.id, selected: 1, offset: 0, path: [], x, y }; return; }
      apps[w.def].mouse(w.app, x - body.x + 1, y - body.y + 1, button, action, body.width);
    }
  }
  function drag(x, y) {
    const c = state.capture; const w = win(c.id); if (!w) return;
    const s = c.bounds; const dx = x - c.x, dy = y - c.y;
    let left = s.x, top = s.y, right = s.x + s.width - 1, bottom = s.y + s.height - 1;
    if (c.edge === "move") { left += dx; top += dy; right += dx; bottom += dy; }
    else {
      if (c.edge.includes("l")) left = Math.min(right - 2, left + dx);
      if (c.edge.includes("r")) right = Math.max(left + 2, right + dx);
      if (c.edge.includes("t")) top = Math.min(bottom - 2, top + dy);
      if (c.edge.includes("b")) bottom = Math.max(top + 2, bottom + dy);
    }
    if (w.mode === "collapsed" && c.edge === "move") { w.bounds.x = clamp(left, 1, state.width - w.bounds.width + 1); w.bounds.y = clamp(top, 2, state.height); return; }
    place(c.id, { x: left, y: top, width: right - left + 1, height: bottom - top + 1 });
  }
  const CURSORS = { move: "move", l: "ew-resize", r: "ew-resize", tb: "ns-resize", b: "ns-resize", lt: "nwse-resize", rb: "nwse-resize", rt: "nesw-resize", lb: "nesw-resize" };
  canvas.addEventListener("pointerdown", (e) => {
    canvas.focus({ preventScroll: true }); e.preventDefault();
    const { x, y } = cellAt(e);
    canvas.setPointerCapture(e.pointerId);
    routePointer(x, y, e.button, "press"); render();
  });
  canvas.addEventListener("pointermove", (e) => {
    const { x, y } = cellAt(e);
    if (state.capture) { drag(x, y); render(); return; }
    if (state.menu) { menuMouse(x, y, 0, "motion"); render(); }
    let cur = "default";
    if (!state.menu && !state.dialog && y > 1) { const w = windowAt(x, y); if (w && w.mode !== "fullscreen") { const rect = bounds(w); const edge = controlAt(w, rect, x, y) ? "" : edgeAt(rect, x, y); if (edge && !(w.mode === "collapsed" && edge !== "move")) cur = CURSORS[edge] || "default"; else if (controlAt(w, rect, x, y)) cur = "pointer"; } }
    if (y === 1 && (x <= 7 || (state.barHits || []).some((h) => x >= h.x && x < h.x + h.width))) cur = "pointer";
    if (cur !== state.hover) { state.hover = cur; canvas.style.cursor = cur; }
  });
  canvas.addEventListener("pointerup", (e) => { if (state.capture) { state.capture = null; render(); } });
  canvas.addEventListener("contextmenu", (e) => e.preventDefault());
  // The page keeps the wheel unless the workspace is focused and the window
  // under the pointer has more content than fits.
  canvas.addEventListener("wheel", (e) => {
    if (document.activeElement !== canvas) return;
    const { x, y } = cellAt(e); const dir = e.deltaY > 0 ? 1 : -1;
    if (state.menu) { e.preventDefault(); menuMouse(x, y, dir, "wheel"); render(); return; }
    const w = windowAt(x, y);
    if (!w || w.mode === "collapsed") return;
    const app = apps[w.def];
    if (!app.scrollable || !app.scrollable(w.app)) return;
    e.preventDefault(); app.wheel(w.app, dir); render();
  }, { passive: false });
  canvas.addEventListener("focus", render); canvas.addEventListener("blur", render);


  // ---------------------------------------------------------------- static scenes
  function sceneWindow(cv, t, rect, title, lines, accent, active) {
    const w = { mode: "floating", accent: accent || "", title, label: "" };
    cv.fill(rect.x, rect.y, rect.width, rect.height, t.border, t.surface);
    drawChrome(cv, w, rect, active !== false, t);
    const body = interior(w, rect);
    lines.forEach((line, i) => {
      if (i >= body.height) return;
      let x = body.x + 1;
      for (const seg of line) { cv.put(x, body.y + i, seg.text, seg.fg === "accent" ? t.accent : seg.fg === "muted" ? t.muted : ACCENT_DARK[seg.fg] ? instanceAccent(t, seg.fg)[0] : seg.fg && seg.fg[0] === "#" ? seg.fg : t.text, seg.bg || t.surface, body.width - (x - body.x)); x += twidth(seg.text); }
    });
  }
  function sceneBar(cv, t, W, tabs, focus) {
    cv.fill(1, 1, W, 1, t.text, t.surface);
    cv.put(1, 1, " BEE ▾ ", selectionText(t), t.accent, 7);
    let x = 8;
    for (const [label, accent] of tabs) {
      const text = " " + label + " ";
      const [ac, fg] = instanceAccent(t, accent);
      if (label === focus) cv.put(x, 1, text, fg, ac); else cv.put(x, 1, text, accent ? ac : t.text, t.surface);
      x += twidth(text);
    }
  }
  function sceneMenu(cv, t, x, y, items, selected) {
    const width = 22, inside = width - 2;
    for (let i = 0; i < items.length + 2; i++) {
      const edge = i === 0 || i === items.length + 1;
      const row = edge ? (i === 0 ? "╭" : "╰") + "─".repeat(inside) + (i === 0 ? "╮" : "╯") : "│" + " ".repeat(inside) + "│";
      cv.put(x, y + i, row, t.border, t.surface, width);
    }
    items.forEach(([label, hint], i) => {
      const sel = i === selected;
      cv.put(x + 2, y + 1 + i, pad(label, inside - 2 - twidth(hint)) + hint, sel ? selectionText(t) : t.text, sel ? t.accent : t.surface, inside - 2);
    });
  }
  function sceneDialog(cv, t, W, H, text, ok) {
    const width = Math.min(W - 4, twidth(text) + 6), height = 6;
    const x = Math.floor((W - width) / 2) + 1, y = Math.floor((H - height) / 2) + 1;
    cv.fill(x, y, width, height, t.text, t.surface);
    cv.put(x, y, "╭" + "─".repeat(width - 2) + "╮", t.accent, t.surface, width);
    for (let yy = y + 1; yy < y + height - 1; yy++) { cv.put(x, yy, "│", t.accent, t.surface, 1); cv.put(x + width - 1, yy, "│", t.accent, t.surface, 1); }
    cv.put(x, y + height - 1, "╰" + "─".repeat(width - 2) + "╯", t.accent, t.surface, width);
    cv.put(x + 2, y, " Claude Code asks ", t.text, t.surface);
    cv.put(x + 2, y + 2, text, t.text, t.surface);
    cv.put(x + 2, y + 4, " Enter " + ok + " ", selectionText(t), t.accent);
    cv.put(x + 4 + twidth(ok) + 8, y + 4, " Esc Cancel ", t.muted, t.surface);
  }
  const L = (...segs) => segs.map((s) => (typeof s === "string" ? A("text", s) : s));
  // Each scene draws the first n of its steps; the loop below advances n.
  const SCENES = {
    build: { steps: 6, draw: (cv, t, W, H, n) => {
      const tabs = [["Claude Code", ""]]; if (n >= 4) tabs.push(["Deploy Board", "green"]);
      sceneBar(cv, t, W, tabs, "Claude Code");
      const lines = [L(A("muted", "> "), "add a deploy board"), []];
      if (n >= 2) lines.push(L(A("accent", "● "), "Write", A("muted", "(apps/deploy_board)")), L(A("muted", "  ⎿  Wrote 48 lines")));
      if (n >= 3) lines.push(L(A("accent", "● "), "freeze", A("muted", " (Governance)")), L(A("muted", "  ⎿  reviewed overlay ready")));
      if (n >= 5) lines.push([], L(A("accent", "● "), "Deploy Board is open."));
      sceneWindow(cv, t, { x: 2, y: 3, width: Math.floor(W * 0.52), height: H - 3 }, "Claude Code", lines);
      if (n >= 4) sceneWindow(cv, t, { x: Math.floor(W * 0.56), y: 5, width: W - Math.floor(W * 0.56) - 1, height: H - 7 }, "Deploy Board", [
        L(A("accent", "DEPLOY BOARD")), L(A("muted", "3 targets")), [],
        L("staging  ", A("green", "✓"), " 1.4.0"), L("prod     ", A("muted", "1.3.2")), L("canary   ", A("muted", "… rolling")),
      ], "green", false);
    } },
    exchange: { steps: 6, draw: (cv, t, W, H, n) => {
      const tabs = [["Codex", ""]]; if (n >= 3) tabs.push(["Claude Code", ""]); if (n >= 5) tabs.push(["Releases", "cyan"]);
      sceneBar(cv, t, W, tabs, n >= 3 ? "Claude Code" : "Codex");
      const half = Math.floor(W / 2);
      const codex = [L(A("accent", "tool bee.thread_append")), L(A("muted", "releases: candidate 1.4.0"))];
      if (n >= 2) codex.push(L(A("accent", "codex")), L("Posted to the releases thread."));
      sceneWindow(cv, t, { x: 2, y: 3, width: half - 2, height: Math.floor(H * 0.55) }, "Codex", codex, "", n < 3);
      if (n >= 3) {
        const claude = [L(A("accent", "● "), "bee:thread_read", A("muted", " (MCP)(releases)")), L(A("muted", "  ⎿  candidate 1.4.0 · codex"))];
        if (n >= 4) claude.push(L(A("accent", "● "), "Running release checks."), L(A("muted", "  ⎿  12 passed")));
        sceneWindow(cv, t, { x: half + 1, y: 3, width: W - half - 1, height: Math.floor(H * 0.55) }, "Claude Code", claude);
      }
      if (n >= 5) sceneWindow(cv, t, { x: Math.floor(W * 0.2), y: Math.floor(H * 0.55) + 3, width: Math.floor(W * 0.6), height: H - Math.floor(H * 0.55) - 3 }, "Releases", [
        L(A("accent", "RELEASES"), A("muted", "  thread · 12 events")),
        L(A("muted", "codex   "), "candidate 1.4.0"), L(A("muted", "claude  "), n >= 6 ? "checks passed" : "checking…"),
      ], "cyan", false);
    } },
    ask: { steps: 5, draw: (cv, t, W, H, n) => {
      sceneBar(cv, t, W, [["Inbox", "amber"], ["Claude Code @ forge", "green"]], n >= 4 ? "Claude Code @ forge" : "Inbox");
      const left = Math.floor(W * 0.56);
      const rows = [L(A("accent", "INBOX"), A("muted", "  workspace · " + (n >= 3 ? "2 pending" : "3 pending"))), []];
      const item = (mark, who, what, when, sel) => {
        const segs = [A(sel ? "accent" : "muted", mark + " "), A(sel ? "text" : "text", what)];
        return { segs, meta: L(A("muted", "   " + who + "  ·  " + when)) };
      };
      const a = item(n >= 3 ? "✓" : "●", "claude @ forge", "ship 1.4.0 to staging", n >= 3 ? "approved · posted" : "12 min left", n >= 2);
      rows.push(a.segs, a.meta);
      const b = item("●", "codex @ desk", "delete 3 stale branches", "2 h left", false);
      rows.push(b.segs, b.meta);
      const c = item("●", "optimize", "run 200 more attempts", "tonight", false);
      rows.push(c.segs, c.meta);
      rows.push([], L(A("accent", n >= 2 && n < 3 ? " Enter Approve " : "        "), A("muted", n >= 2 && n < 3 ? "  D Deny   Esc Later" : "")));
      sceneWindow(cv, t, { x: 2, y: 3, width: left - 2, height: H - 3 }, "Inbox", rows, "amber", n < 4);
      const lines = [L(A("accent", "● "), "Checks passed on 1.4.0."), L(A("accent", "● "), "bee:ask", A("muted", " (MCP)(ship to staging?)"))];
      if (n < 3) lines.push(L(A("muted", "  ⎿  filed · waiting in your inbox")));
      else lines.push(L(A("muted", "  ⎿  approved by you · 11:42")));
      if (n >= 4) lines.push([], L(A("accent", "● "), "Bash", A("muted", "(deploy staging 1.4.0)")));
      if (n >= 5) lines.push(L(A("muted", "  ⎿  staging is on 1.4.0")));
      sceneWindow(cv, t, { x: left + 1, y: 3, width: W - left - 1, height: H - 3 }, "Claude Code @ forge", lines, "green", n >= 4);
    } },
    hub: { steps: 5, draw: (cv, t, W, H, n) => {
      sceneBar(cv, t, W, [["Claude Code", ""], ["Hub", ""]], n >= 3 ? "Hub" : "Claude Code");
      if (n >= 3) {
        const rows = [L(A("accent", "HUB"), A("muted", "  host-authorized")), [],
          L("kanban        0.3  ", n >= 4 ? A("muted", "installed") : A("accent", "install")),
          L("sql-console   1.1  ", A("muted", "installed")), L("deploy-board  0.9  ", A("muted", "installed")), L("test-watch    1.0  ", A("muted", "installed"))];
        if (n >= 5) rows.push([], L(A("muted", "kanban is under Tools now")));
        sceneWindow(cv, t, { x: Math.floor(W * 0.4), y: 3, width: W - Math.floor(W * 0.4) - 1, height: H - 3 }, "Hub", rows);
      }
      if (n <= 2 || n >= 5) sceneMenu(cv, t, 1, 2, [["Terminal", ""], ["Agents", "›"], ["Tools", "›"], ["Hub", "›"], ["Exit", "Ctrl+Q"]], n >= 5 ? 2 : n >= 2 ? 3 : 0);
      if (n >= 5) sceneMenu(cv, t, 1, 9, [["Settings", ""], ["Process Manager", ""], ["Kanban", ""], ["Deploy Board", ""], ["SQL Console", ""]], 2);
    } },
    research: { steps: 7, draw: (cv, t, W, H, n) => {
      const tabs = [["Claude Code", ""]]; if (n >= 3) tabs.push(["Optimize", "violet"]);
      sceneBar(cv, t, W, tabs, n >= 3 ? "Optimize" : "Claude Code");
      const left = Math.floor(W * 0.4);
      const lines = [L(A("muted", "> "), "p95 under 120ms, keep going"), []];
      if (n >= 2) lines.push(L(A("accent", "● "), "freeze", A("muted", " (Governance)(optimize)")), L(A("muted", "  ⎿  watcher · workflow · db")));
      if (n >= 3) lines.push(L(A("accent", "● "), "bee:thread_message", A("muted", " (MCP)(perf)")), L(A("muted", "  ⎿  durable report on the thread")));
      if (n >= 7) lines.push([], L(A("accent", "● "), "bee:thread_read", A("muted", " (MCP)(perf)")), L(A("muted", "  ⎿  goal met at run 61 · 118ms")));
      sceneWindow(cv, t, { x: 2, y: 3, width: left - 2, height: H - 3 }, "Claude Code", lines, "", n < 3);
      if (n >= 3) {
        const runs = n >= 7 ? 61 : n >= 6 ? 44 : n >= 5 ? 27 : n >= 4 ? 10 : 2;
        const width = W - left - 1, inner = width - 4;
        const cols = Math.min(inner, 50);
        const mix = (a, b, k) => "#" + [0, 2, 4].map((i) => Math.round(parseInt(a.slice(1 + i, 3 + i), 16) * (1 - k) + parseInt(b.slice(1 + i, 3 + i), 16) * k).toString(16).padStart(2, "0")).join("");
        const g1 = instanceAccent(t, "green")[0], g2 = mix(g1, t.surface, 0.28), rose = instanceAccent(t, "rose")[0];
        const total = 500, failing = Math.max(0, Math.round(37 * (1 - runs / 61)));
        const failSet = new Set(); for (let i = 0; i < failing; i++) failSet.add((i * 7919 + 13) % total);
        const gridRows = Math.ceil(total / (cols * 2));
        const grid = [];
        for (let r = 0; r < gridRows; r++) {
          const segs = [];
          for (let c = 0; c < cols; c++) {
            const top = r * 2 * cols + c, bottom = top + cols;
            const color = (i) => (i >= total ? t.surface : failSet.has(i) ? rose : ((i % cols) + Math.floor(i / cols)) % 2 ? g2 : g1);
            segs.push({ fg: color(top), bg: color(bottom), text: "▀" });
          }
          grid.push(segs);
        }
        const vals = [];
        for (let i = 0; i < cols; i++) { const p = i / (cols - 1); const shown = p <= runs / 61; vals.push(shown ? 310 - 192 * Math.min(1, p * 1.05) + ((i * 7919) % 11) * 2 : null); }
        const lo = 100, hi = 330, rowsN = 3;
        const chart = []; for (let r = 0; r < rowsN; r++) chart.push([]);
        const BARS8 = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"];
        vals.forEach((v) => {
          const frac = v == null ? 0 : (v - lo) / (hi - lo);
          const eighths = Math.round(frac * rowsN * 8);
          for (let r = 0; r < rowsN; r++) { const rowFromBottom = rowsN - 1 - r; const e = eighths - rowFromBottom * 8; chart[r].push(e <= 0 ? " " : e >= 8 ? "█" : BARS8[e - 1]); }
        });
        const p95 = runs >= 61 ? "118ms" : runs >= 27 ? "204ms" : "296ms";
        const body = [
          L(A("accent", "OPTIMIZE"), A("muted", "  goal p95 < 120ms · run " + runs + " · local")),
          L(A("muted", "tests 500  "), A("green", "✓ " + (total - failing)), A("muted", "  "), A(failing ? "rose" : "muted", "✗ " + failing)),
          ...grid,
          [],
          L(A("muted", "p95  310ms → "), A(runs >= 61 ? "green" : "text", p95), A("muted", runs >= 61 ? "  goal met · posted to perf" : "  change › bench › compare")),
          ...chart.map((row) => L(A("accent", row.join("")))),
        ];
        sceneWindow(cv, t, { x: left + 1, y: 3, width, height: H - 3 }, "Optimize", body, "violet");
      }
    } },
    swarm: { steps: 6, draw: (cv, t, W, H, n) => {
      const tabs = [["Claude Code", ""]]; if (n >= 3) tabs.push(["Triage swarm", "violet"]);
      sceneBar(cv, t, W, tabs, n >= 3 ? "Triage swarm" : "Claude Code");
      const left = Math.floor(W * 0.5);
      const lines = [L(A("muted", "> "), "triage 4,000 issues by tonight"), []];
      if (n >= 2) lines.push(L(A("accent", "● "), "Write", A("muted", "(swarm/triage.flow)")), L(A("muted", "  ⎿  fetch › classify ×12 › report")));
      if (n >= 3) lines.push(L(A("accent", "● "), "freeze", A("muted", " (Governance)(swarm/triage)")), L(A("muted", "  ⎿  bounded agent actions · governed model")));
      if (n >= 6) lines.push([], L(A("accent", "● "), "Done: 4,000 triaged."), L(A("muted", "  ⎿  report posted to the thread")));
      sceneWindow(cv, t, { x: 2, y: 3, width: left - 2, height: H - 3 }, "Claude Code", lines, "", n < 3);
      if (n >= 3) {
        const done = n >= 6 ? 4000 : n >= 5 ? 3180 : n >= 4 ? 1240 : 0;
        const width = W - left - 1, inner = width - 4;
        const bar = Math.max(1, inner - 12), filled = Math.round((done / 4000) * bar);
        const body = [
          L(A("accent", "TRIAGE"), A("muted", "  bounded dataflow · 12 actions")),
          L(A("muted", "fetch ─┬─ classify ×12 ─┬─ dedupe ── report")),
          L(A("muted", "       └─ " + (n >= 4 ? "local 12" : "starting…"))), [],
          L(A("green", "█".repeat(filled)), A("muted", "░".repeat(bar - filled) + "  " + String(done).padStart(5) + "/4000")),
          L(A("muted", "model  local · governed action budget")),
          L(A("muted", "bugs 1,204 · features 812 · dupes 391 · noise 773")),
        ];
        if (n >= 6) body.push([], L(A("green", "✓ report posted to thread issues")));
        sceneWindow(cv, t, { x: left + 1, y: 3, width, height: H - 3 }, "Triage swarm", body, "violet");
      }
    } },
    hive: { steps: 5, draw: (cv, t, W, H, n) => {
      const tabs = [["Claude Code", ""], ["Hive Manager", ""]]; if (n >= 4) tabs.push(["Catalog", "cyan"]);
      sceneBar(cv, t, W, tabs, n >= 4 ? "Catalog" : "Hive Manager");
      const left = Math.floor(W * 0.55);
      const rows = [L(A("accent", "HIVE"), A("muted", "  admitted local operations")), [], L(A("muted", "surface       owner")),
        L("catalog       ", A("muted", "descriptive")), L("policy        ", A("muted", "host ceiling"))];
      if (n >= 2) rows.push(L("threads       ", A("muted", "durable")), L("approvals     ", A("muted", "owner")));
      if (n >= 3) rows.push([], L(A("accent", "› inspect operation catalog")));
      sceneWindow(cv, t, { x: 2, y: 3, width: left - 2, height: H - 3 }, "Hive Manager", rows, "", n < 4);
      if (n >= 4) sceneWindow(cv, t, { x: left + 1, y: 5, width: W - left - 1, height: H - 7 }, "Catalog", [
        L(A("muted", "operation $ "), "thread_read"),
        L(A("muted", "operation $ "), "approval_status"),
        ...(n >= 5 ? [L(A("muted", "owner   "), "authorization required"), L(A("muted", "catalog "), "generation current")] : []),
      ], "cyan");
    } },
  };
  const sceneCanvases = [];
  const sceneState = new WeakMap();
  function paintScene(el) {
    const t = theme(state.prefs.theme);
    const c2 = el.getContext("2d");
    const d = Math.min(2, window.devicePixelRatio || 1);
    const width = el.parentElement.clientWidth;
    const fs = width < 420 ? 11 : width < 640 ? 12 : 13;
    c2.font = fs + "px " + FONT;
    const w = Math.ceil(c2.measureText("M".repeat(20)).width / 20 * 100) / 100;
    const hh = Math.round(fs * 1.3);
    const W = Math.max(40, Math.floor(width / w)), H = 18;
    el.width = Math.round(W * w * d); el.height = Math.round(H * hh * d);
    el.style.width = Math.round(W * w) + "px"; el.style.height = H * hh + "px";
    const cv = new Cells(W, H); cv.clear(t.text, t.ground);
    for (let y = 1; y <= H; y++) cv.put(1, y, backgroundRow(state.prefs.background, W, y, H), t.pattern, t.ground, W);
    const scene = SCENES[el.dataset.scene];
    const st = sceneState.get(el) || { n: scene.steps };
    scene.draw(cv, t, W, H, st.n);
    paint(el, cv, t, { ctx: c2, cw: w, chh: hh, fontSize: fs, dpr: d }, null);
  }
  const reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  function animateScene(el) {
    const scene = SCENES[el.dataset.scene];
    const st = sceneState.get(el) || { n: 1, timer: null, visible: false };
    sceneState.set(el, st);
    const tick = () => {
      if (!st.visible) { st.timer = null; return; }
      st.n = st.n >= scene.steps ? 1 : st.n + 1;
      paintScene(el);
      st.timer = setTimeout(tick, st.n >= scene.steps ? 3200 : st.n === 1 ? 1200 : 900);
    };
    return { start() { if (!st.timer) { st.visible = true; st.n = 1; paintScene(el); st.timer = setTimeout(tick, 1200); } }, stop() { st.visible = false; clearTimeout(st.timer); st.timer = null; } };
  }
  const animators = new Map();
  if ("IntersectionObserver" in window && !reduceMotion) {
    const io = new IntersectionObserver((entries) => {
      for (const en of entries) {
        let a = animators.get(en.target); if (!a) { a = animateScene(en.target); animators.set(en.target, a); }
        if (en.isIntersecting) a.start(); else a.stop();
      }
    }, { threshold: 0.35 });
    document.querySelectorAll("canvas[data-scene]").forEach((el) => io.observe(el));
  }
  function paintScenes() { document.querySelectorAll("canvas[data-scene]").forEach(paintScene); }

  // ---------------------------------------------------------------- page theme
  function applyPageTheme() {
    const t = theme(state.prefs.theme); const root = document.documentElement.style;
    for (const k of ["ground", "surface", "text", "muted", "border", "accent", "pattern"]) root.setProperty("--" + k, t[k]);
    root.setProperty("--on-accent", selectionText(t));
    document.querySelectorAll(".sw").forEach((b) => b.setAttribute("aria-pressed", b.dataset.theme === t.id ? "true" : "false"));
    try { localStorage.setItem("bee.prefs", JSON.stringify(state.prefs)); } catch (_) {}
    if (typeof paintScenes === "function" && sceneCanvases.ready) paintScenes();
  }
  const swatches = document.getElementById("swatches");
  for (const t of THEMES) {
    const b = document.createElement("button"); b.className = "sw"; b.dataset.theme = t.id; b.type = "button";
    b.innerHTML = '<div class="g" style="background:' + t.ground + '"><i style="background:' + t.accent + '"></i><i style="background:' + t.border + '"></i><i style="background:' + t.muted + '"></i><i style="background:' + t.surface + '"></i></div><div class="n" style="background:' + t.surface + ";color:" + t.text + '">' + t.title + "</div>";
    b.addEventListener("click", () => { state.prefs.theme = t.id; applyPageTheme(); render(); });
    swatches.appendChild(b);
  }
  const wsid = document.getElementById("wsid"); if (wsid) wsid.textContent = state.workspace;
  fetch("https://api.github.com/repos/wippyai/bee").then((r) => (r.ok ? r.json() : null)).then((d) => {
    const el = document.getElementById("stars");
    if (d && typeof d.stargazers_count === "number" && el) { el.textContent = d.stargazers_count >= 1000 ? (d.stargazers_count / 1000).toFixed(1) + "k" : String(d.stargazers_count); el.hidden = false; }
  }).catch(() => {});
  document.querySelectorAll(".copy").forEach((copy) => {
    const label = copy.textContent;
    copy.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(copy.dataset.cmd); copy.textContent = "Copied"; } catch (_) { copy.textContent = "Select and copy the line"; }
      setTimeout(() => { copy.textContent = label; }, 1800);
    });
  });
  document.querySelectorAll("[data-replay]").forEach((b) => b.addEventListener("click", (e) => {
    e.preventDefault(); replayScene();
    document.getElementById("try").scrollIntoView({ behavior: "smooth", block: "start" });
    canvas.focus({ preventScroll: true });
  }));

  // The headline types " live" once the visitor reaches it or points at it.
  (function () {
    const el = document.getElementById("typed"); if (!el) return;
    let done = false;
    const type = () => {
      if (done) return; done = true;
      const text = " live"; let i = 0;
      const step = () => { el.textContent = text.slice(0, ++i); if (i < text.length) setTimeout(step, 140 + Math.random() * 90); };
      setTimeout(step, 1600);
    };
    const h1 = el.parentElement;
    h1.addEventListener("pointerenter", type);
    if ("IntersectionObserver" in window) new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) type(); }, { threshold: 0.9 }).observe(h1);
  })();

  // ---------------------------------------------------------------- boot
  try { const saved = JSON.parse(localStorage.getItem("bee.prefs") || "null"); if (saved && theme(saved.theme).id === saved.theme && BACKGROUNDS.includes(saved.background)) state.prefs = { theme: saved.theme, background: saved.background, taskbar: saved.taskbar === "icons" ? "icons" : "labels" }; } catch (_) {}
  applyPageTheme();
  function start() {
    measure();
    for (let i = 0; i < 40; i++) sample();
    render();
    openScene();
    setStatus("Click in, then type. F1 opens the menu.", 9000); render();
    sceneCanvases.ready = true; paintScenes();
    setInterval(() => { blinkOn = !blinkOn; if (blinkOn) sample(); render(); }, 500);
  }
  function openScene() {
    const a = area(); const W = a.width, H = a.height;
    if (W < 100) { openApp("claude", { fullscreen: true }); return; }
    const c = openApp("claude", { title: "Claude Code @ forge" });
    place(c.id, { x: 3, y: a.y + 1, width: Math.round(W * 0.54), height: Math.round(H * 0.88) });
  }
  function launchCodexFromClaude(prompt) {
    const a = area(); const W = a.width, H = a.height;
    const keep = state.focus;
    const x = openApp("codex", { prompt, from: "claude code · thread agents · mcp", title: "Codex @ desk" });
    if (W >= 100) place(x.id, { x: Math.round(W * 0.59), y: a.y + 2, width: Math.round(W * 0.39), height: Math.round(H * 0.4) });
    else x.mode = "fullscreen";
    setStatus("Codex joined thread agents", 3000);
    if (keep && W >= 100) focusWindow(keep);
  }
  function claudeSay(segs) {
    const w = state.windows.find((x) => x.def === "claude"); if (!w) return;
    const last = w.app.lines[w.app.lines.length - 1];
    if (segs[0] && segs[0].fg === "accent" && last && last.length) w.app.lines.push([]);
    w.app.lines.push(segs);
  }
  function replayScene() {
    for (const w of state.windows) if (w.app && w.app.busy) clearTimeout(w.app.busy);
    state.windows = []; state.order = []; state.zorder = []; state.focus = ""; state.menu = null; state.dialog = null;
    for (const id of ["testwatch", "testlint"]) { const i = CATALOG.findIndex((d) => d.id === id); if (i >= 0) CATALOG.splice(i, 1); }
    clearTimeout(watch.timer); watch.cells = initialWatch(); watch.run = 1; watch.at = Date.now(); inbox.state = "pending";
    openScene(); setStatus("Replaying", 1500); render();
  }
  let resizeTimer;
  window.addEventListener("resize", () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(() => { measure(); render(); paintScenes(); }, 80); });
  const ready = document.fonts ? document.fonts.load('15px "IBM Plex Mono"').catch(() => null) : Promise.resolve();
  ready.then(start);
})();
