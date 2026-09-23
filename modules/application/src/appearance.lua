-- Semantic desktop colors and validated presentation preferences.
-- ok, warn and error are status roles: they color a state word or a data mark
-- past a declared threshold, always beside text that carries the same meaning.
type Theme = {id: string, title: string, ground: string, surface: string, text: string,
    muted: string, border: string, accent: string, pattern: string, ok: string, warn: string, error: string,
    on_accent: string?, terminal_text: string?, terminal_surface: string?}
type Page = {foreground: string, background: string}
type Preferences = {theme: string, background: string, taskbar: string?}
local M = {}
local themes: {Theme} = {
    {id = "honey", title = "Honey", ground = "#0c1119", surface = "#17202c", text = "#d8e2ef", muted = "#8999ad", border = "#6f89a5", accent = "#ffc963", pattern = "#1c2937", ok = "#7ee787", warn = "#ffa657", error = "#ff7b72"},
    {id = "ocean", title = "Ocean", ground = "#071720", surface = "#102b39", text = "#d6f0f4", muted = "#88adb9", border = "#4b8599", accent = "#67dce5", pattern = "#1a3542", ok = "#7ee787", warn = "#ffa657", error = "#ff7b72"},
    {id = "forest", title = "Forest", ground = "#101a16", surface = "#1c2b23", text = "#e0ecdf", muted = "#96af9e", border = "#628773", accent = "#b6d884", pattern = "#283c30", ok = "#7ee787", warn = "#ffa657", error = "#ff7b72"},
    {id = "plum", title = "Plum", ground = "#19121f", surface = "#2b2034", text = "#eee0f2", muted = "#b2a0bd", border = "#9478a6", accent = "#e4acf1", pattern = "#34243e", ok = "#7ee787", warn = "#ffa657", error = "#ff7b72"},
    {id = "ember", title = "Ember", ground = "#1c1311", surface = "#30201c", text = "#f4e4d8", muted = "#bda598", border = "#a87964", accent = "#ffa879", pattern = "#3a2820", ok = "#7ee787", warn = "#ffa657", error = "#ff7b72"},
    {id = "graphite", title = "Graphite", ground = "#111315", surface = "#222629", text = "#e8edef", muted = "#a0a9ae", border = "#76828a", accent = "#c3d8e6", pattern = "#2b3034", ok = "#7ee787", warn = "#ffa657", error = "#ff7b72"},
    {id = "paper", title = "Paper", ground = "#e9e6dd", surface = "#f5f2ea", text = "#303b3e", muted = "#58666b", border = "#7d8785", accent = "#87560c", pattern = "#cfcec6", ok = "#1a7f37", warn = "#9a6700", error = "#cf222e"},
    {id = "aurora", title = "Aurora", ground = "#0b1720", surface = "#152b35", text = "#def7ed", muted = "#91b8ad", border = "#578f89", accent = "#82f0ba", pattern = "#203a43", ok = "#7ee787", warn = "#ffa657", error = "#ff7b72"},
    {id = "rose", title = "Rose", ground = "#21131c", surface = "#38212e", text = "#f8e5ed", muted = "#c9a1b4", border = "#a7748d", accent = "#ffa5c5", pattern = "#422839", ok = "#7ee787", warn = "#ffa657", error = "#ff7b72"},
    {id = "cobalt", title = "Cobalt", ground = "#0c142b", surface = "#192749", text = "#e0eaff", muted = "#9cadcf", border = "#667fae", accent = "#87b6ff", pattern = "#24365b", ok = "#7ee787", warn = "#ffa657", error = "#ff7b72"},
    {id = "sand", title = "Sand", ground = "#e8dcc8", surface = "#f4ead9", text = "#493e30", muted = "#72634e", border = "#9e8b6e", accent = "#9e4e28", pattern = "#cec1a9", ok = "#1a7f37", warn = "#9a6700", error = "#cf222e"},
    {id = "midnight", title = "Midnight", ground = "#07090e", surface = "#141822", text = "#e0e5f0", muted = "#929db5", border = "#5d6c89", accent = "#c1b5ff", pattern = "#202638", ok = "#7ee787", warn = "#ffa657", error = "#ff7b72"},
    {id = "lavender", title = "Lavender", ground = "#e8e2f0", surface = "#f5effb", text = "#42394f", muted = "#75677f", border = "#9b8eaa", accent = "#75509d", pattern = "#d0c5dc", ok = "#1a7f37", warn = "#9a6700", error = "#cf222e"},
    {id = "mono", title = "Mono", ground = "#0d0d0d", surface = "#242424", text = "#ededed", muted = "#aaaaaa", border = "#777777", accent = "#ffffff", pattern = "#2b2b2b", ok = "#cfcfcf", warn = "#e6e6e6", error = "#ffffff"},
    {id = "dos", title = "DOS Blue", ground = "#000080", surface = "#0000aa", text = "#ffffff", muted = "#aaaaaa", border = "#55ffff", accent = "#ffff55", pattern = "#0000aa", ok = "#55ff55", warn = "#ffaa00", error = "#ff5555"},
    {id = "classic", title = "Windows Classic", ground = "#008080", surface = "#c0c0c0", text = "#000000", muted = "#505050", border = "#606060", accent = "#000080", pattern = "#006b6b", ok = "#005a00", warn = "#6b4400", error = "#8b0000", on_accent = "#ffffff", terminal_text = "#cccccc", terminal_surface = "#0c0c0c"},
}
local backgrounds: {string} = {"dots", "solid", "grid", "horizon", "stars", "weave", "crosshatch", "bricks", "diagonal", "waves", "hex"}
type Pattern = {period: integer, rows: {string}}
local function pattern(period: integer, rows: {string}): Pattern return {period = period, rows = rows} end
local patterns: {[string]: Pattern} = {
    dots = pattern(8, {"        ", "   ·    ", "        "}),
    grid = pattern(4, {"┼───", "│   "}),
    stars = pattern(8, {"+       ", "    ·   ", "        ", "  ·     "}),
    weave = pattern(8, {"──  │   ", "    │   ", "│   ──  ", "│       "}),
    crosshatch = pattern(4, {"╲ ╱ ", " ╳  ", "╱ ╲ ", "    "}),
    bricks = pattern(8, {"────┬───", "    │   ", "┬───┴───", "│       "}),
    diagonal = pattern(4, {"╲   ", " ╲  ", "  ╲ ", "   ╲"}),
    waves = pattern(6, {"∙  ∙  ", " ∙∙ ∙∙", "      "}),
    hex = pattern(4, {"⬡   ", "  ⬡ "}),
}
-- Shared wallpaper samples for the desktop and the Settings thumbnails.
-- Callers clip the returned repeated tile to their canvas rectangle.
function M.background_row(id: string, width: integer, y: integer, height: integer): string
    local pattern = patterns[id]
    if pattern then
        return string.rep(pattern.rows[(y - 1) % #pattern.rows + 1], width // pattern.period + 1)
    end
    if id == "horizon" and y >= height * 2 / 3 and y % 2 == 0 then return string.rep("─", width) end
    return string.rep(" ", width)
end
-- Selection text is independent of wallpaper color (notably on classic navy).
function M.selection_text(theme: Theme): string return theme.on_accent or theme.ground end
-- Named instance accents affect chrome only. Each palette has a paired readable
-- selection foreground; application page colors stay owned by the global theme.
local accent_dark: {[string]: string} = {amber = "#ffc963", cyan = "#67dce5", green = "#a6df8a", rose = "#ffa5c5", violet = "#d3b0ff"}
local accent_light: {[string]: string} = {amber = "#9c6200", cyan = "#006d80", green = "#28703a", rose = "#9f3158", violet = "#744394"}
function M.instance_accent(theme: Theme, name: string?): (string, string)
    if not name or name == "" then return theme.accent, M.selection_text(theme) end
    local dark, light = accent_dark[name], accent_light[name]
    if not dark or not light then return theme.accent, M.selection_text(theme) end
    local r = tonumber(theme.surface:sub(2, 3), 16) or 0
    local g = tonumber(theme.surface:sub(4, 5), 16) or 0
    local b = tonumber(theme.surface:sub(6, 7), 16) or 0
    if r * 0.299 + g * 0.587 + b * 0.114 > 128 then return light, "#ffffff" end
    return dark, "#000000"
end
function M.themes(): {Theme} return themes end
-- The color of a named semantic role: surface, text, muted, border, accent, ok,
-- warn or error. Any other name is text.
function M.role(theme: Theme, name: string?): string
    if name == "surface" then return theme.surface end
    if name == "muted" then return theme.muted end
    if name == "border" then return theme.border end
    if name == "accent" then return theme.accent end
    if name == "ok" then return theme.ok end
    if name == "warn" then return theme.warn end
    if name == "error" then return theme.error end
    return theme.text
end
-- The color k of the way from a to b (0 is a, 1 is b), for intensity ramps
-- between the surface and a role.
function M.mix(a: string, b: string, k: number): string
    local weight = math.max(0, math.min(1, k))
    local parts: {string} = {}
    for _, first in ipairs({2, 4, 6}) do
        local x = tonumber(a:sub(first, first + 1), 16) or 0
        local y = tonumber(b:sub(first, first + 1), 16) or 0
        parts[#parts + 1] = string.format("%02x", math.floor(x + (y - x) * weight + 0.5))
    end
    return "#" .. table.concat(parts)
end
function M.page(theme: Theme, terminal: boolean): Page
    if terminal then
        return {foreground = theme.terminal_text or theme.text, background = theme.terminal_surface or theme.surface}
    end
    return {foreground = theme.text, background = theme.surface}
end
function M.backgrounds(): {string} return backgrounds end
function M.defaults(): Preferences return {theme = "honey", background = "dots", taskbar = "labels"} end
function M.theme(id: string): Theme
    for _, item in ipairs(themes) do if item.id == id then return item end end
    return themes[1]
end
function M.decode(value: unknown): Preferences?
    if type(value) ~= "table" or type(value.theme) ~= "string" or type(value.background) ~= "string" then return nil end
    if M.theme(value.theme).id ~= value.theme then return nil end
    if value.taskbar ~= nil and value.taskbar ~= "labels" and value.taskbar ~= "icons" then return nil end
    for _, background in ipairs(backgrounds) do
        if value.background == background then return {theme = value.theme, background = background, taskbar = value.taskbar == "icons" and "icons" or "labels"} end
    end
    return nil
end
function M.cycle(value: Preferences, field: string): Preferences
    local next_value: Preferences = {theme = value.theme, background = value.background, taskbar = value.taskbar}
    if field == "theme" then
        for index, item in ipairs(themes) do
            if item.id == value.theme then next_value.theme = themes[index % #themes + 1].id; break end
        end
    elseif field == "background" then
        for index, item in ipairs(backgrounds) do
            if item == value.background then next_value.background = backgrounds[index % #backgrounds + 1]; break end
        end
    end
    return next_value
end
local function rgb(hex: string): string
    return tostring(tonumber(hex:sub(2, 3), 16)) .. ";" .. tostring(tonumber(hex:sub(4, 5), 16)) .. ";" .. tostring(tonumber(hex:sub(6, 7), 16))
end
function M.style(foreground: string, background: string): string
    return "\27[38;2;" .. rgb(foreground) .. "m\27[48;2;" .. rgb(background) .. "m"
end
return M
