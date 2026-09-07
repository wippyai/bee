-- Semantic desktop colors and validated presentation preferences.
type Theme = {id: string, title: string, ground: string, surface: string, text: string,
    muted: string, border: string, accent: string, pattern: string, on_accent: string?}
type Preferences = {theme: string, background: string, taskbar: string?}
local M = {}
local themes: {Theme} = {
    {id = "honey", title = "Honey", ground = "#0c1119", surface = "#17202c", text = "#d8e2ef", muted = "#8999ad", border = "#6f89a5", accent = "#ffc963", pattern = "#1c2937"},
    {id = "ocean", title = "Ocean", ground = "#071720", surface = "#102b39", text = "#d6f0f4", muted = "#88adb9", border = "#4b8599", accent = "#67dce5", pattern = "#1a3542"},
    {id = "forest", title = "Forest", ground = "#101a16", surface = "#1c2b23", text = "#e0ecdf", muted = "#96af9e", border = "#628773", accent = "#b6d884", pattern = "#283c30"},
    {id = "plum", title = "Plum", ground = "#19121f", surface = "#2b2034", text = "#eee0f2", muted = "#b2a0bd", border = "#9478a6", accent = "#e4acf1", pattern = "#34243e"},
    {id = "ember", title = "Ember", ground = "#1c1311", surface = "#30201c", text = "#f4e4d8", muted = "#bda598", border = "#a87964", accent = "#ffa879", pattern = "#3a2820"},
    {id = "graphite", title = "Graphite", ground = "#111315", surface = "#222629", text = "#e8edef", muted = "#a0a9ae", border = "#76828a", accent = "#c3d8e6", pattern = "#2b3034"},
    {id = "paper", title = "Paper", ground = "#e9e6dd", surface = "#f5f2ea", text = "#303b3e", muted = "#58666b", border = "#7d8785", accent = "#87560c", pattern = "#cfcec6"},
    {id = "aurora", title = "Aurora", ground = "#0b1720", surface = "#152b35", text = "#def7ed", muted = "#91b8ad", border = "#578f89", accent = "#82f0ba", pattern = "#203a43"},
    {id = "rose", title = "Rose", ground = "#21131c", surface = "#38212e", text = "#f8e5ed", muted = "#c9a1b4", border = "#a7748d", accent = "#ffa5c5", pattern = "#422839"},
    {id = "cobalt", title = "Cobalt", ground = "#0c142b", surface = "#192749", text = "#e0eaff", muted = "#9cadcf", border = "#667fae", accent = "#87b6ff", pattern = "#24365b"},
    {id = "sand", title = "Sand", ground = "#e8dcc8", surface = "#f4ead9", text = "#493e30", muted = "#72634e", border = "#9e8b6e", accent = "#9e4e28", pattern = "#cec1a9"},
    {id = "midnight", title = "Midnight", ground = "#07090e", surface = "#141822", text = "#e0e5f0", muted = "#929db5", border = "#5d6c89", accent = "#c1b5ff", pattern = "#202638"},
    {id = "lavender", title = "Lavender", ground = "#e8e2f0", surface = "#f5effb", text = "#42394f", muted = "#75677f", border = "#9b8eaa", accent = "#75509d", pattern = "#d0c5dc"},
    {id = "mono", title = "Mono", ground = "#0d0d0d", surface = "#242424", text = "#ededed", muted = "#aaaaaa", border = "#777777", accent = "#ffffff", pattern = "#2b2b2b"},
    {id = "dos", title = "DOS Blue", ground = "#000080", surface = "#0000aa", text = "#ffffff", muted = "#aaaaaa", border = "#55ffff", accent = "#ffff55", pattern = "#0000aa"},
    {id = "classic", title = "Windows Classic", ground = "#008080", surface = "#c0c0c0", text = "#000000", muted = "#505050", border = "#606060", accent = "#000080", pattern = "#006b6b", on_accent = "#ffffff"},
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
function M.themes(): {Theme} return themes end
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
