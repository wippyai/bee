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

M.REVISION = "bee.governance-component-guide@3"
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
-- inline, which renders through the terminal toolkit. It paints one line,
-- counts key presses and leaves on CANCEL.
M.SOURCE = [==[local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")
local json = require("json")
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid launch") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local receipts = assert(process.listen("bee.application.checkpoint_result", {message = true}))
    local count = 0
    if launch.resume_state ~= "" then
        local state: unknown = json.decode(launch.resume_state)
        if type(state) ~= "table" or type(state.count) ~= "number" then error("Invalid counter checkpoint") end
        count = math.floor(state.count)
    end
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local saved = -1
    local function paint()
        local canvas = tty.canvas(width, height)
        canvas:clear(" ")
        canvas:put(1, 1, "COUNTER APP", width)
        canvas:put(1, 2, "Count: " .. tostring(count), width)
        canvas:put(1, 3, "Saved: " .. tostring(saved), width)
        assert(output:present(canvas:rows()))
    end
    local function checkpoint()
        assert(client.checkpoint(launch, json.encode({count = count})))
    end
    paint()
    client.ready(launch)
    checkpoint()
    while true do
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), receipts:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then break end
        elseif event.channel == receipts then
            local message = event.value
            local data: unknown = message:payload():data()
            if message:from() == launch.broker_pid and type(data) == "table" and data.error_code == "" then
                saved = count; paint()
            end
        elseif event.value.type == "close" then checkpoint()
        elseif event.value.type == "resize" then width, height = event.value.width, event.value.height; paint()
        elseif event.value.type == "key" and event.value.action ~= "release" then count = count + 1; paint(); checkpoint() end
    end
    output:close(); tty.stop()
end
return {main = main}
]==]

-- The example entries.json value: one application definition, the exact shape
-- the freeze and publication path measures. Its metadata is the minimum
-- docs/APPLICATION_CONTRACTS.md requires for an admitted, listed application.
M.NAMESPACE = "bee.guide_demo"
M.DEFINITION_ID = M.NAMESPACE .. ":app"
M.TITLE = "Counter App"
M.VERSION = "1.0.0"

function M.example(): {{[string]: unknown}}
    return {{id = M.DEFINITION_ID, kind = "process.lua",
        data = {source = M.SOURCE, method = "main",
            modules = {"tty", "process", "channel", "json"},
            imports = {client = "bee.application:client"}},
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
        .. " metadata declares a resume_schema. Declare exactly the native modules and library imports"
        .. " the source uses."
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
        .. " matches. For a terminal UI, search the " .. table.concat(M.TERMINAL_TOPICS, ", ")
        .. " topics for the toolkit, layout, styles and input. Read the guide once, then look every question"
        .. " up in the corpus rather than guessing a signature."
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
