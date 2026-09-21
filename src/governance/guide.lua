-- MIT. The component authoring guide a bound agent reads through the MCP
-- overlay tool. Pure: it composes bounded text from this repository's own
-- rule sources (the preflight CONFIG tables it imports) and carries one
-- minimal example. It reads no store, executes nothing and grants nothing.
--
-- The example is the same value tests/fixtures/app_journey authors through the
-- real workspace -> publication -> destination -> preflight chain, so the
-- guide's example and the proven example cannot drift apart.
local preflight = require("preflight")
local json = require("json")
local M = {}

M.REVISION = "bee.governance-component-guide@4"
M.SCHEMA = "bee.governance-artifact@1"
M.ENTRIES_PATH = "entries.json"

-- The two kinds of declared field the destination's typed config reads
-- differently. These are the enforcing tables, imported rather than restated.
local CONFIG_LISTS = preflight.CONFIG_LISTS
local CONFIG_OBJECTS = preflight.CONFIG_OBJECTS

local function join(values: {string}): string
    if #values == 1 then return values[1] end
    if #values == 2 then return values[1] .. " and " .. values[2] end
    return table.concat(values, ", ", 1, #values - 1) .. " and " .. values[#values]
end

-- One clause per kind and field the destination checks, built from the tables
-- preflight enforces so a rule change cannot leave the guide stale. Each clause
-- is self-contained, so it is checkable against the enforcing table by itself.
function M.config_shape_rule(): string
    local clauses: {string} = {}
    local kind_order: {string} = {}
    for kind in pairs(CONFIG_LISTS) do kind_order[#kind_order + 1] = kind end
    for kind in pairs(CONFIG_OBJECTS) do kind_order[#kind_order + 1] = kind end
    table.sort(kind_order)
    local seen: {[string]: boolean} = {}
    for _, kind in ipairs(kind_order) do
        if not seen[kind] then
            seen[kind] = true
            local names: {string} = {}
            for field in pairs(CONFIG_LISTS[kind] or {}) do names[#names + 1] = field end
            for field in pairs(CONFIG_OBJECTS[kind] or {}) do names[#names + 1] = field end
            table.sort(names)
            for _, field in ipairs(names) do
                if (CONFIG_LISTS[kind] or {})[field] then
                    clauses[#clauses + 1] = kind .. " reads " .. field .. " as a list"
                else
                    clauses[#clauses + 1] = kind .. " reads " .. field .. " as a named object"
                end
            end
        end
    end
    return "The destination unpacks each entry's configuration into a typed config: "
        .. join(clauses) .. "; and an empty declared field of either kind"
        .. " reaches the destination as neither shape."
end

local CONFIG_SHAPE_RULE = M.config_shape_rule()

-- The minimal application: one process.lua entry carrying its Lua source
-- inline, which renders a small responsive terminal surface with semantic
-- appearance, keyboard/mouse parity and honest checkpoint feedback.
M.SOURCE = [==[local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")
local json = require("json")
local appearance = require("appearance")

local RESET = "\27[0m"

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid launch") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local receipts = assert(process.listen("bee.application.checkpoint_result", {message = true}))
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    local count = 0
    if launch.resume_state ~= "" then
        local state: unknown = json.decode(launch.resume_state)
        if type(state) ~= "table" or type(state.count) ~= "number"
            or state.count ~= math.floor(state.count) or state.count < 0 then
            error("Invalid counter checkpoint")
        end
        count = math.floor(state.count)
    end
    assert(tty.start())
    assert(tty.mouse(true))
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local saved: integer? = nil
    local pending_request_id: string? = nil
    local pending_count: integer? = nil
    local status = "Ready"
    local running = true
    local action_y = 0
    local increment_x, increment_width = 0, 0
    local exit_x, exit_width = 0, 0

    local function clip(value: string, room: integer): string
        if room <= 0 then return "" end
        return tty.text.truncate(value:gsub("%c", " "), room, "…")
    end

    local function fit(value: string, room: integer): string
        local clipped = clip(value, room)
        return clipped .. string.rep(" ", math.max(0, room - tty.text.width(clipped)))
    end

    local function paint()
        local theme = appearance.theme(preferences.theme)
        local canvas = tty.canvas(width, height)
        local function line(y: integer, value: string, foreground: string?, background: string?)
            if y < 1 or y > height then return end
            local fg = foreground or theme.text
            local bg = background or theme.surface
            canvas:put(1, y, appearance.style(fg, bg) .. fit(value, width) .. RESET, width)
        end
        local function put(x: integer, y: integer, value: string, foreground: string, background: string): integer
            if x < 1 or x > width or y < 1 or y > height then return 0 end
            local room = width - x + 1
            local clipped = clip(value, room)
            canvas:put(x, y, appearance.style(foreground, background) .. clipped .. RESET, room)
            return tty.text.width(clipped)
        end
        canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
        for y = 1, height do line(y, "") end

        local title = height >= 3 and "COUNTER APP" or "COUNTER APP · " .. tostring(count)
        line(1, title, theme.text)
        if height >= 5 then
            line(2, "WORK", theme.muted)
            line(3, "Count: " .. tostring(count), theme.accent)
            local saved_text = saved == nil and "Saved: —" or "Saved: " .. tostring(saved)
            line(4, saved_text, theme.muted)
        elseif height >= 4 then
            line(2, "Count: " .. tostring(count), theme.accent)
        end

        action_y = height >= 2 and height or 0
        if height >= 3 then line(height - 1, "Status: " .. status, theme.muted) end
        increment_x, increment_width, exit_x, exit_width = 0, 0, 0, 0
        if action_y > 0 then
            line(action_y, "", theme.text)
            local increment_label = width >= 24 and " [Enter] Add one " or (width >= 10 and " [Enter] +1 " or " +1 ")
            local exit_label = width >= 24 and " [Escape] Exit " or (width >= 10 and " [Esc] Exit " or " Esc ")
            local x = width >= 2 and 2 or 1
            local increment_size = tty.text.width(increment_label)
            if x + increment_size - 1 <= width then
                increment_x, increment_width = x, put(x, action_y, increment_label, appearance.selection_text(theme), theme.accent)
                x = x + increment_width + 1
            end
            local exit_size = tty.text.width(exit_label)
            if x + exit_size - 1 <= width then
                exit_x, exit_width = x, put(x, action_y, exit_label, theme.text, theme.surface)
            end
        end
        assert(output:present(canvas:rows()))
    end

    local function checkpoint()
        local request_id = client.checkpoint(launch, json.encode({count = count}))
        if request_id then
            pending_request_id, pending_count = request_id, count
            status = "Saving count " .. tostring(count)
        else
            pending_request_id, pending_count = nil, nil
            status = "Save unavailable"
        end
        paint()
    end

    local function increment()
        count = count + 1
        checkpoint()
    end

    local appearance_request_id = launch.instance_id
    assert(process.send(launch.broker_pid, "bee.appearance.request", {version = 1,
        request_id = appearance_request_id, op = "state"}))
    paint()
    client.ready(launch)
    checkpoint()
    while running do
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), receipts:case_receive(), states:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == states then
            local message = event.value
            local data: unknown = message:payload():data()
            if message:from() == launch.broker_pid and type(data) == "table" and data.version == 1 then
                local next_preferences = appearance.decode(data)
                if next_preferences then preferences = next_preferences; paint() end
            end
        elseif event.channel == receipts then
            local message = event.value
            local data: unknown = message:payload():data()
            if message:from() == launch.broker_pid and type(data) == "table" and data.version == 1
                and type(data.request_id) == "string" and data.request_id == pending_request_id then
                local submitted = pending_count
                pending_request_id, pending_count = nil, nil
                if data.error_code == "" and submitted ~= nil then
                    saved = submitted
                    status = "Saved count " .. tostring(submitted)
                elseif data.error_code == "superseded" then
                    status = "Save superseded"
                else
                    status = "Save failed"
                end
                paint()
            end
        else
            local data = event.value
            if data.type == "close" then running = false
            elseif data.type == "resize" then width, height = data.width, data.height; paint()
            elseif data.type == "key" and data.action == "press" then
                if data.key_type == "enter" then increment()
                elseif data.key_type == "escape" or data.key_type == "esc" then running = false end
            elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                local x, y = math.floor(tonumber(data.x) or 0), math.floor(tonumber(data.y) or 0)
                if y == action_y and x >= increment_x and x < increment_x + increment_width then increment()
                elseif y == action_y and x >= exit_x and x < exit_x + exit_width then running = false end
            end
        end
    end
    process.unlisten(states); process.unlisten(receipts)
    output:close(); tty.mouse(false); tty.stop()
end
return {main = main}
]==]

-- The example entries.json value: one application definition, the exact shape
-- the freeze and publication path measures. Its metadata is the minimum
-- docs/reference/applications.md requires for an admitted, listed application.
M.NAMESPACE = "bee.guide_demo"
M.DEFINITION_ID = M.NAMESPACE .. ":app"
M.TITLE = "Counter App"
M.VERSION = "1.0.0"

function M.example(): {{[string]: unknown}}
    return {{id = M.DEFINITION_ID, kind = "process.lua",
        data = {source = M.SOURCE, method = "main",
            modules = {"tty", "process", "channel", "json"},
            imports = {client = "bee.application:client", appearance = "bee.desktop:appearance"}},
        meta = {type = "bee.application", application = {api_version = 1, lifetime = "view",
            revision = "1", title = M.TITLE, instance_policy = "multiple",
            resume_schema = "guide-counter.v1", restart_policy = "automatic"}}}}
end

function M.example_json(): (string?, string?)
    return json.encode(M.example())
end

local DELIVERY_STEPS = {"review the plan in Overlays", "select it there",
    "prepare the activation there", "approve it in Approvals",
    "let the activation owner apply the overlay",
    "open it from the start menu"}

-- The steps a person takes after an agent requests delivery. Exposed so the
-- delivery tool and the guide cannot disagree about who does what.
function M.delivery_steps(): {string}
    local copied: {string} = {}
    for index, step in ipairs(DELIVERY_STEPS) do copied[index] = step end
    return copied
end

function M.document(): string
    local lines: {string} = {}
    lines[#lines + 1] = "Bee component authoring guide (" .. M.REVISION .. ")"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "A component pack is one frozen file, " .. M.ENTRIES_PATH
        .. ", holding a JSON list of complete native registry entries. Each entry has id, kind,"
        .. " an optional meta and a required data; put source, method, modules and imports inside data."
        .. " Source is inline Lua text, never a file URL. Top-level YAML shorthand is not the registry API."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "A pack may contain process.lua applications, function.lua tools, library.lua support code,"
        .. " registry.entry declarations and security.policy entries. Installed metadata describes a capability;"
        .. " it never grants that capability. The destination separately constrains namespaces, entry kinds,"
        .. " native modules, policy grants and resource bindings during preflight, and the activation owner alone"
        .. " applies the reviewed overlay. Use the read-only components tool to inspect the effective installed"
        .. " registry and exact Hub package entries, documentation and examples before authoring."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "An application is one process.lua entry with meta.type bee.application and a"
        .. " meta.application record declaring api_version 1, lifetime view, a nonempty revision and title,"
        .. " and instance_policy singleton or multiple. Metadata describes the application; it never"
        .. " authorizes it. The host separately admits the definition, and the broker lists it only once"
        .. " the effective catalog carries it. Advance the application revision whenever executable source"
        .. " or configuration changes; a revision identifies one exact runnable definition."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "The process entry carries its Lua source inline and renders with the terminal"
        .. " toolkit: tty.events, tty.start, tty.surface, tty.screen_size, tty.canvas with one-based"
        .. " canvas:put, output:present, client.launch, client.ready, and client.checkpoint when the"
        .. " metadata declares a resume_schema. Use semantic appearance roles from"
        .. " bee.desktop:appearance, authenticate appearance messages by their broker sender, and"
        .. " declare exactly the native modules and library imports the source uses."
    lines[#lines + 1] = ""
    lines[#lines + 1] = CONFIG_SHAPE_RULE
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Every authoring operation except guide names its overlay_id; it is distinct from the agent's runtime workspace."
    lines[#lines + 1] = "Freeze copies the complete measured file set into owned storage and binds it to"
        .. " the overlay identity and revision; it does not change the edit revision, and later edits"
        .. " cannot change a frozen snapshot. Freeze is not approval, installation or execution."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "After freeze, publication prepare parses " .. M.ENTRIES_PATH
        .. " from that exact snapshot into the canonical artifact (" .. M.SCHEMA
        .. "). Requesting delivery stages the version at this destination and reads its preflight verdict;"
        .. " a refusal names the diagnostic and its remedy. Then a person must " .. join(DELIVERY_STEPS)
        .. ". Only the activation owner may write an overlay. A pack may append migration functions for an"
        .. " existing host-admitted database when every imported dependency is already installed and no"
        .. " auto-start consumer is present. Governance seals the exact functions and runs them before exposing"
        .. " the complete overlay. New databases, changed applied migrations and schema rollback are refused."
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.platform_documentation()
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Minimal example: put the JSON below at path " .. M.ENTRIES_PATH
        .. " and freeze it. Its entry id is " .. M.DEFINITION_ID .. " and its title " .. M.TITLE .. "."
    return table.concat(lines, "\n")
end

-- Where the platform documentation lives and how to look things up with the
-- read-only docs tool. It names the topics for cross-node applications and for
-- terminal UIs by their corpus names, so the guide and the tool cannot describe
-- different corpora for long.
M.DOCS_REVISION = "bee.docs-corpus@1"
M.CROSS_NODE_TOPICS = {"cluster", "process", "registry"}
M.TERMINAL_TOPICS = {"terminal", "ui", "component"}
function M.platform_documentation(): string
    return "The platform documentation ships inside Bee and works offline: the docs tool"
        .. " (" .. M.DOCS_REVISION .. ") reads the corpus with list, search and read, bounded the way this"
        .. " tool is. list names the topics and document ids; search takes one literal phrase and returns"
        .. " the section each match sits under; read takes a document id and returns one bounded window,"
        .. " with section naming a heading anchor to start there. It covers the runtime modules you declare"
        .. " or call (process, channel, tty, registry, sql, fs, http, events, time and the rest), Bee's own"
        .. " contracts (application, threads, hive, placement and subscriptions, gateway, carrier, storage,"
        .. " UI) and the terminal toolkit. For an application that works across every node, search the "
        .. table.concat(M.CROSS_NODE_TOPICS, ", ") .. " topics for hive, subscriptions and placement and read the"
        .. " matches. The authored UI rules are in docs/guides/ui.md, and the canonical runnable"
        .. " UI Guide source is src/apps/stylebook/ (Tools → Learn); it is reference source, not a widget"
        .. " framework. For a terminal UI, search the " .. table.concat(M.TERMINAL_TOPICS, ", ")
        .. " topics for the toolkit, layout, styles and input. Read the guide once, then look every"
        .. " question up in the corpus rather than guessing a signature."
end

-- The value the MCP overlay tool returns for its read-only guide operation.
function M.value(): {[string]: unknown}
    local encoded, encode_error = M.example_json()
    if not encoded then return {revision = M.REVISION, document = M.document(), example_error = tostring(encode_error)} end
    return {revision = M.REVISION, document = M.document(),
        example = {path = M.ENTRIES_PATH, entries_json = encoded, definition_id = M.DEFINITION_ID,
            title = M.TITLE, version = M.VERSION, source = M.SOURCE}}
end

return M
