-- MIT. Copying text out of windows. A left drag inside a window body selects
-- its text and copies on release, while a click without motion reaches the
-- app; a double click copies a word and a triple click a line. Quick copy
-- labels the copyable tokens of the focused window with hints to type. Copy
-- mode moves a cursor over the window's text, selects by characters or
-- lines, and searches. Every mode works on one frozen snapshot of the
-- window, bounded to it; the shell routes input here and writes the text
-- each outcome carries to the clipboard.
local tty = require("tty")
local selection = require("selection")
local hints = require("hints")
local model = require("model")
local layout = require("layout")

type Rect = model.Rect
type Point = selection.Point
-- An outcome: the events the window's app receives, the text to copy, and
-- the status to show. pass hands the event on to the shell's own routing.
type Outcome = {forward: {tty.InputEvent}, copy: string?, status: string?, pass: boolean?}
-- A left press held back from the app until it is a click or a drag.
type Pending = {id: string, x: integer, y: integer, event: tty.MouseEvent, state: selection.State}
type Click = {id: string, x: integer, y: integer, at: integer, count: integer}
-- mode is "drag", "cursor" or "hints". In copy mode marking says a range
-- runs from the anchor to the cursor; query is the search being typed and
-- searched the last search.
type Active = {mode: string, id: string, state: selection.State, cursor: Point, anchor: Point?, lines: boolean,
    tokens: {hints.Token}, typed: string, query: string?, searched: string}
type Controller = {active: Active?, pending: Pending?, click: Click?}
-- A mark the renderer draws over the frozen rows: cells first to last of row
-- y in role "selection", "cursor", "token" or "label" (with text).
type Mark = {y: integer, first: integer, last: integer, role: string, text: string?}
type Overlay = {id: string, width: integer, height: integer, rows: {string}, marks: {Mark}}

local M = {}

-- MULTI_CLICK_MS is the longest pause between the clicks of a double or
-- triple click.
M.MULTI_CLICK_MS = 400

M.COPY_STATUS = "Copy mode · v select · y copy"
M.HINT_STATUS = "Quick copy · type a hint · Esc"

function M.new(): Controller return {} end

local function none(): Outcome return {forward = {}} end

-- body is the interior of window id when it shows on scene.
function M.body(scene: model.Scene, id: string): Rect?
    for _, win in ipairs(model.visible(scene)) do
        if win.id == id and win.mode ~= "collapsed" then return layout.interior(win, layout.rectangle(scene, win, nil, nil)) end
    end
    return nil
end

-- binding names window id's body as the selection's view.
local function binding(id: string, body: Rect): selection.Binding
    return {view_id = id, attachment = id, mount_generation = 0, width = body.width, height = body.height}
end

-- capture freezes rows, a window's content, within its body.
local function capture(id: string, body: Rect, rows: {string}): (selection.State?, string?)
    local cut: {string} = {}
    for y = 1, body.height do cut[y] = tty.text.cut(rows[y] or "", 0, body.width) end
    return selection.capture(binding(id, body), cut)
end

local function characters(value: string): integer
    local count = 0
    for index = 1, #value do
        local byte = value:byte(index)
        if byte < 0x80 or byte >= 0xC0 then count = count + 1 end
    end
    return count
end

-- report is the status after the shell asked the clipboard to take text.
function M.report(value: string, copied: boolean, problem: string?): string
    if not copied then return "Copy failed: " .. tostring(problem or "the terminal refused the clipboard") end
    local count = characters(value)
    return "Copied " .. count .. (count == 1 and " character" or " characters")
end

local function relative(event: tty.MouseEvent, body: Rect): tty.MouseEvent
    return {type = "mouse", x = event.x - body.x + 1, y = event.y - body.y + 1, action = event.action,
        button = event.button, ctrl = event.ctrl, alt = event.alt, shift = event.shift}
end

local function copied(state: selection.State): Outcome
    local value, problem = selection.text(state)
    if not value or value == "" then return {forward = {}, status = "Nothing copied: " .. tostring(problem or "the selection is empty")} end
    return {forward = {}, copy = value}
end

function M.view(ctl: Controller): string?
    local active, pending = ctl.active, ctl.pending
    if active then return active.id end
    if pending then return pending.id end
    return nil
end

-- holding is whether pointer input belongs to the controller wherever it
-- moves: a press held back or a drag in progress.
function M.holding(ctl: Controller): boolean
    local active = ctl.active
    return ctl.pending ~= nil or (active ~= nil and active.mode == "drag")
end

-- engaged is whether every input belongs to the controller.
function M.engaged(ctl: Controller): boolean return ctl.active ~= nil or ctl.pending ~= nil end

function M.cancel(ctl: Controller)
    ctl.active, ctl.pending = nil, nil
end

-- forget drops what the controller holds of window id.
function M.forget(ctl: Controller, id: string)
    if M.view(ctl) == id then M.cancel(ctl) end
    local click = ctl.click
    if click and click.id == id then ctl.click = nil end
end

-- pointer takes a mouse event inside window id's body, with rows its
-- content. An app that takes drags receives every event as it comes.
function M.pointer(ctl: Controller, id: string, body: Rect, rows: {string}, event: tty.MouseEvent, now: integer, drags: boolean): Outcome
    local inside = relative(event, body)
    if drags or event.action ~= "press" or event.button ~= "left" then return {forward = {inside}} end
    local state, problem = capture(id, body, rows)
    if not state then return {forward = {inside}, status = "Text selection unavailable: " .. tostring(problem)} end
    local click = ctl.click
    if click and click.id == id and click.x == inside.x and click.y == inside.y and now - click.at <= M.MULTI_CLICK_MS then
        click.count, click.at = click.count + 1, now
        if click.count == 2 then return copied(selection.word(state, inside.x, inside.y)) end
        ctl.click = nil
        return copied(selection.line(state, inside.y))
    end
    ctl.click = nil
    ctl.pending = {id = id, x = inside.x, y = inside.y, event = inside, state = state}
    return none()
end

-- begin starts copy mode, or quick copy when mode is "hints", over window
-- id's body showing rows.
function M.begin(ctl: Controller, mode: string, id: string, body: Rect, rows: {string}): Outcome
    M.cancel(ctl)
    local state, problem = capture(id, body, rows)
    if not state then return {forward = {}, status = "Text selection unavailable: " .. tostring(problem)} end
    local tokens: {hints.Token} = {}
    if mode == "hints" then
        local plain: {string} = {}
        for y = 1, selection.height(state) do plain[y] = selection.plain(state, y) end
        tokens = hints.tokens(plain)
        if #tokens == 0 then return {forward = {}, status = "Quick copy · nothing to copy here"} end
    end
    local last = 1
    for y = selection.height(state), 1, -1 do
        if selection.plain(state, y):find("%S") then last = y; break end
    end
    ctl.active = {mode = mode, id = id, state = state, cursor = {x = 1, y = last}, lines = false, tokens = tokens,
        typed = "", searched = ""}
    return {forward = {}, status = mode == "hints" and M.HINT_STATUS or M.COPY_STATUS}
end

local function escape(event: tty.TTYEvent): boolean
    return event.type == "key" and event.action ~= "release" and event.key_type == "esc"
end

local function letter(event: tty.KeyEvent): string?
    if event.ctrl or event.alt or event.key_type ~= "runes" or #event.key ~= 1 then return nil end
    return event.key
end

local function on_pending(ctl: Controller, pending: Pending, event: tty.TTYEvent, body: Rect, now: integer): Outcome
    if event.type ~= "mouse" then
        ctl.pending = nil
        return {forward = {pending.event}, pass = true}
    end
    local inside = relative(event, body)
    if event.action == "release" then
        ctl.pending = nil
        ctl.click = {id = pending.id, x = pending.x, y = pending.y, at = now, count = 1}
        return {forward = {pending.event, inside}}
    end
    if event.action == "motion" and (inside.x ~= pending.x or inside.y ~= pending.y) then
        ctl.pending = nil
        local state = selection.drag(selection.press(pending.state, pending.x, pending.y), inside.x, inside.y)
        ctl.active = {mode = "drag", id = pending.id, state = state, cursor = {x = inside.x, y = inside.y}, lines = false,
            tokens = {}, typed = "", searched = ""}
    end
    return none()
end

local function on_drag(ctl: Controller, active: Active, event: tty.TTYEvent, body: Rect): Outcome
    if escape(event) then M.cancel(ctl); return {forward = {}, status = ""} end
    if event.type ~= "mouse" then return none() end
    local inside = relative(event, body)
    if event.action == "motion" then
        active.state = selection.motion(active.state, inside.x, inside.y)
    elseif event.action == "release" then
        local state = selection.release(active.state, inside.x, inside.y)
        ctl.active = nil
        return copied(state)
    end
    return none()
end

local function on_hints(ctl: Controller, active: Active, event: tty.TTYEvent): Outcome
    if escape(event) then M.cancel(ctl); return {forward = {}, status = ""} end
    if event.type == "mouse" and event.action == "press" then M.cancel(ctl); return {forward = {}, status = ""} end
    if event.type ~= "key" or event.action == "release" then return none() end
    if event.key_type == "backspace" then active.typed = active.typed:sub(1, -2); return none() end
    local typed = letter(event)
    if not typed then return none() end
    local chosen, partial = hints.choose(active.tokens, active.typed .. typed:lower())
    if chosen then
        ctl.active = nil
        return {forward = {}, copy = chosen.text}
    end
    if partial then active.typed = active.typed .. typed:lower(); return none() end
    active.typed = ""
    return {forward = {}, status = "Quick copy · no hint " .. typed}
end

local function mark(active: Active)
    local anchor = active.anchor
    if anchor then active.state = selection.span(active.state, anchor, active.cursor, active.lines)
    else active.state = selection.clear(active.state) end
end

local function search(active: Active, step: integer): Outcome
    if active.searched == "" then return {forward = {}, status = "Search: type / first"} end
    local found = selection.find(active.state, active.searched, active.cursor, step)
    if not found then return {forward = {}, status = "No match: " .. active.searched} end
    active.cursor = found
    mark(active)
    return {forward = {}, status = "/" .. active.searched .. " · n N"}
end

local function on_query(active: Active, event: tty.KeyEvent, query: string): Outcome
    local kind = event.key_type
    if kind == "esc" then active.query = nil; return {forward = {}, status = M.COPY_STATUS} end
    if kind == "enter" then
        active.query = nil
        active.searched = query
        return search(active, 1)
    end
    if kind == "backspace" then query = (query:gsub("[^\128-\191][\128-\191]*$", ""))
    elseif kind == "space" then query = query .. " "
    elseif kind == "runes" and not event.ctrl and not event.alt then query = query .. event.key end
    active.query = query
    return {forward = {}, status = "/" .. query}
end

local function on_cursor(ctl: Controller, active: Active, event: tty.TTYEvent, body: Rect): Outcome
    if event.type == "mouse" then
        local inside = relative(event, body)
        if event.action == "press" and event.button == "left" then
            active.state = selection.press(active.state, inside.x, inside.y)
            active.cursor, active.anchor = {x = inside.x, y = inside.y}, nil
        elseif event.action == "motion" then
            active.state = selection.motion(active.state, inside.x, inside.y)
        elseif event.action == "release" and selection.dragging(active.state) then
            local state = selection.release(active.state, inside.x, inside.y)
            ctl.active = nil
            return copied(state)
        end
        return none()
    end
    if event.type ~= "key" or event.action == "release" then return none() end
    local query = active.query
    if query then return on_query(active, event, query) end
    local kind, key = event.key_type, letter(event)
    local width, height = selection.width(active.state), selection.height(active.state)
    local cursor = active.cursor
    local x, y = cursor.x, cursor.y
    if kind == "esc" or key == "q" then M.cancel(ctl); return {forward = {}, status = ""} end
    if kind == "enter" or key == "y" or (event.ctrl and event.key:lower() == "c") then
        if not selection.range(active.state) then return {forward = {}, status = "Nothing selected · v or V"} end
        ctl.active = nil
        return copied(active.state)
    end
    if kind == "left" or key == "h" then x = x - 1
    elseif kind == "right" or key == "l" then x = x + 1
    elseif kind == "up" or key == "k" then y = y - 1
    elseif kind == "down" or key == "j" then y = y + 1
    elseif kind == "pgup" then y = y - (height - 1)
    elseif kind == "pgdown" then y = y + (height - 1)
    elseif kind == "home" or key == "0" then x = 1
    elseif kind == "end" or key == "$" then x = math.max(1, tty.text.width((selection.plain(active.state, y):gsub("%s+$", ""))))
    elseif key == "g" then x, y = 1, 1
    elseif key == "G" then x, y = 1, height
    elseif key == "v" or key == "V" then
        local lines = key == "V"
        if active.anchor and active.lines == lines then active.anchor = nil
        else active.anchor, active.lines = active.anchor or {x = x, y = y}, lines end
    elseif key == "/" then active.query = ""; return {forward = {}, status = "/"}
    elseif key == "n" then return search(active, 1)
    elseif key == "N" then return search(active, -1)
    else return none() end
    active.cursor = {x = math.floor(math.max(1, math.min(width, x))), y = math.floor(math.max(1, math.min(height, y)))}
    mark(active)
    return none()
end

-- input takes an event while the controller is engaged, with body the
-- current interior of its window, nil when the window no longer shows.
function M.input(ctl: Controller, event: tty.TTYEvent, body: Rect?, now: integer): Outcome
    local active, pending = ctl.active, ctl.pending
    local id = M.view(ctl)
    local state = active and active.state or (pending and pending.state)
    if not body or not id or not selection.valid(state, binding(id, body)) then
        M.cancel(ctl)
        return {forward = {}, status = "Text selection unavailable: the window changed", pass = event.type ~= "mouse"}
    end
    if pending then return on_pending(ctl, pending, event, body, now) end
    if not active then return {forward = {}, pass = true} end
    if active.mode == "drag" then return on_drag(ctl, active, event, body) end
    if active.mode == "hints" then return on_hints(ctl, active, event) end
    return on_cursor(ctl, active, event, body)
end

-- overlay is what the renderer draws over the controller's window: the
-- frozen rows with the selection, the copy mode cursor or the hints.
function M.overlay(ctl: Controller): Overlay?
    local active = ctl.active
    if not active then return nil end
    local state = active.state
    local snapshot = selection.snapshot(state)
    local marks: {Mark} = {}
    local span = selection.range(state)
    if span then
        for y = span.start.y, span.finish.y do
            marks[#marks + 1] = {y = y, first = y == span.start.y and span.start.x or 1,
                last = y == span.finish.y and span.finish.x or snapshot.binding.width, role = "selection"}
        end
    end
    if active.mode == "cursor" then
        marks[#marks + 1] = {y = active.cursor.y, first = active.cursor.x, last = active.cursor.x, role = "cursor"}
    end
    for _, token in ipairs(active.tokens) do
        if token.label:sub(1, #active.typed) == active.typed then
            local last = token.finish == token.y and token.last or snapshot.binding.width
            marks[#marks + 1] = {y = token.y, first = token.first, last = last, role = "token"}
            local label = token.label:sub(#active.typed + 1)
            marks[#marks + 1] = {y = token.y, first = token.first, last = token.first + #label - 1, role = "label", text = label}
        end
    end
    return {id = active.id, width = snapshot.binding.width, height = snapshot.binding.height, rows = snapshot.rows, marks = marks}
end

return M
