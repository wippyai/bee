-- MIT. Semantic desktop colors and presentation preferences.
--
-- A theme is a palette over fixed roles. Themes are registry entries of type
-- TYPE (data: title and one #rrggbb color per role), so any module can add
-- one; the node resolves the chosen entry and hands the palette to displays
-- and apps, which never read themes from the registry themselves.
--
-- ok, warn and error are status roles: they color a state word or a data mark
-- past a declared threshold, always beside text that carries the same meaning.
type Theme = {id: string, title: string, ground: string, surface: string, text: string,
    muted: string, border: string, accent: string, pattern: string, ok: string, warn: string, error: string,
    on_accent: string?, on_accent_background: string?, terminal_text: string?, terminal_surface: string?}
type Page = {foreground: string, background: string}
-- Preferences are what a display paints with: the node's palette, the
-- background pattern and the taskbar style.
type Preferences = {theme: Theme, background: string, taskbar: string}
local M = {}

M.TYPE = "bee.ui.theme"
-- TOPIC carries appearance changes to running apps as {appearance = value}.
M.TOPIC = "bee.ui.appearance"
M.ROLES = {"ground", "surface", "text", "muted", "border", "accent", "pattern", "ok", "warn", "error"}
M.OPTIONAL_ROLES = {"on_accent", "on_accent_background", "terminal_text", "terminal_surface"}

local fallback: Theme = {id = "", title = "Default", ground = "#0c1119", surface = "#17202c", text = "#d8e2ef",
    muted = "#8999ad", border = "#6f89a5", accent = "#ffc963", pattern = "#1c2937", ok = "#7ee787",
    warn = "#ffa657", error = "#ff7b72"}

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
    local found = patterns[id]
    if found then
        return string.rep(found.rows[(y - 1) % #found.rows + 1], width // found.period + 1)
    end
    if id == "horizon" and y >= height * 2 / 3 and y % 2 == 0 then return string.rep("─", width) end
    return string.rep(" ", width)
end

-- Selection text is independent of wallpaper color (notably on classic navy).
function M.selection_text(theme: Theme): string return theme.on_accent or theme.ground end

-- Named instance accents affect chrome only. Each palette has a paired readable
-- selection foreground; application page colors stay owned by the theme.
local accent_dark: {[string]: string} = {amber = "#ffc963", cyan = "#67dce5", green = "#a6df8a", rose = "#ffa5c5", violet = "#d3b0ff"}
local accent_terminal: {[string]: string} = {amber = "ansi:3", cyan = "ansi:6", green = "ansi:2", rose = "ansi:1", violet = "ansi:5"}
local accent_light: {[string]: string} = {amber = "#9c6200", cyan = "#006d80", green = "#28703a", rose = "#9f3158", violet = "#744394"}
function M.instance_accent(theme: Theme, name: string?): (string, string)
    if not name or name == "" then return theme.accent, M.selection_text(theme) end
    local dark, light = accent_dark[name], accent_light[name]
    if not dark or not light then return theme.accent, M.selection_text(theme) end
    if theme.surface == "default" then return assert(accent_terminal[name]), M.selection_text(theme) end
    local r = tonumber(theme.surface:sub(2, 3), 16) or 0
    local g = tonumber(theme.surface:sub(4, 5), 16) or 0
    local b = tonumber(theme.surface:sub(6, 7), 16) or 0
    if r * 0.299 + g * 0.587 + b * 0.114 > 128 then return light, "#ffffff" end
    return dark, "#000000"
end

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
    if a:sub(1, 1) ~= "#" or b:sub(1, 1) ~= "#" then return weight == 0 and a or b end
    local parts: {string} = {}
    for _, first in ipairs({2, 4, 6}) do
        local x = tonumber(a:sub(first, first + 1), 16) or 0
        local y = tonumber(b:sub(first, first + 1), 16) or 0
        parts[#parts + 1] = string.format("%02x", math.floor(x + (y - x) * weight + 0.5))
    end
    return "#" .. table.concat(parts)
end

-- The page colors of an app viewport; terminal apps may use their own pair.
function M.page(theme: Theme, terminal: boolean): Page?
    local foreground = terminal and (theme.terminal_text or theme.text) or theme.text
    local background = terminal and (theme.terminal_surface or theme.surface) or theme.surface
    if foreground == "default" and background == "default" then return nil end
    return {foreground = foreground, background = background}
end

function M.backgrounds(): {string} return backgrounds end

function M.background_known(id: string): boolean
    for _, item in ipairs(backgrounds) do
        if item == id then return true end
    end
    return false
end

function M.default_theme(): Theme return fallback end

function M.defaults(): Preferences return {theme = fallback, background = "dots", taskbar = "labels"} end

local function color(value: unknown): string?
    if type(value) ~= "string" then return nil end
    if value:match("^#%x%x%x%x%x%x$") or value == "default" or value == "default:dim" or value == "default:reverse" then return value end
    local index = value:match("^ansi:(%d+)$")
    if index and tonumber(index) < 16 then return value end
    return nil
end

-- decode_theme validates a palette: an id, a title, a #rrggbb color for every
-- role and, when present, for the optional roles.
function M.decode_theme(value: unknown): Theme?
    if type(value) ~= "table" or type(value.id) ~= "string" or type(value.title) ~= "string" then return nil end
    local ground, surface, text, muted = color(value.ground), color(value.surface), color(value.text), color(value.muted)
    local border, accent, pattern_color = color(value.border), color(value.accent), color(value.pattern)
    local ok, warn, err = color(value.ok), color(value.warn), color(value.error)
    if not ground or not surface or not text or not muted or not border or not accent or not pattern_color
        or not ok or not warn or not err then
        return nil
    end
    for _, role in ipairs(M.OPTIONAL_ROLES) do
        if value[role] ~= nil and not color(value[role]) then return nil end
    end
    return {id = value.id, title = value.title, ground = ground, surface = surface, text = text, muted = muted,
        border = border, accent = accent, pattern = pattern_color, ok = ok, warn = warn, error = err,
        on_accent = color(value.on_accent), on_accent_background = color(value.on_accent_background), terminal_text = color(value.terminal_text),
        terminal_surface = color(value.terminal_surface)}
end

-- decode validates preferences as a node sends them: {theme = palette,
-- background = id, taskbar = "labels" | "icons"}.
function M.decode(value: unknown): Preferences?
    if type(value) ~= "table" then return nil end
    local theme = M.decode_theme(value.theme)
    if not theme or type(value.background) ~= "string" or not M.background_known(value.background) then return nil end
    if value.taskbar ~= "labels" and value.taskbar ~= "icons" then return nil end
    return {theme = theme, background = value.background, taskbar = value.taskbar}
end

-- chosen returns the preferences a {appearance = value} carries (an app's
-- start options or a TOPIC message), or the defaults.
function M.chosen(value: unknown): Preferences
    if type(value) == "table" then
        local decoded = M.decode(value.appearance)
        if decoded then return decoded end
    end
    return M.defaults()
end

local function rgb(hex: string): string
    return tostring(tonumber(hex:sub(2, 3), 16)) .. ";" .. tostring(tonumber(hex:sub(4, 5), 16)) .. ";" .. tostring(tonumber(hex:sub(6, 7), 16))
end

local function sgr(value: string, background: boolean): string
    local base = background and 40 or 30
    if value == "default" then return "\27[" .. tostring(base + 9) .. "m" end
    if value == "default:dim" then return "\27[" .. tostring(base + 9) .. ";2m" end
    if value == "default:reverse" then return "\27[" .. tostring(base + 9) .. ";7m" end
    local index = value:match("^ansi:(%d+)$")
    if index then
        local number = assert(tonumber(index))
        return "\27[" .. tostring(number < 8 and base + number or base + 60 + number - 8) .. "m"
    end
    return "\27[" .. tostring(base + 8) .. ";2;" .. rgb(value) .. "m"
end

function M.style(foreground: string, background: string): string
    return sgr(foreground, false) .. sgr(background, true)
end

return M
