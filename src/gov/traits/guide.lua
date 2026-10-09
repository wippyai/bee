-- MIT. The component authoring guide a bound agent reads through the MCP
-- overlay tool. Pure: it composes bounded text from this repository's own
-- rule sources (the preflight CONFIG tables it imports) and carries one
-- minimal example. It reads no store, executes nothing and grants nothing.
--
-- The example is the same value tests/fixtures/app_journey authors through the
-- real workspace -> publication -> destination -> preflight chain, so the
-- guide's example and the proven example cannot drift apart.
local preflight = require("preflight")
local workspace_applications = require("workspace_applications")
local drivers = require("drivers")
local json = require("json")
local hive_sdk_example = require("hive_sdk_example")
local M = {}

M.REVISION = "bee.governance-component-guide@18"
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
-- inline, which renders a small responsive terminal surface through the
-- shared application frame, with keyboard/mouse parity and honest
-- checkpoint feedback.
M.SOURCE = [==[local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")
local json = require("json")
local appearance = require("appearance")
local frame = require("frame")

local HINTS = frame.hints({{key = "Enter", verb = "add one"}, {key = "Esc", verb = "exit"}})

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid launch") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local receipts = assert(process.listen("bee.app.checkpoint_result", {message = true}))
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
    local hits: {frame.Hit} = {}

    local function paint()
        local painter = frame.new(width, height, preferences)
        local theme = painter.theme
        frame.header(painter, "COUNTER APP", height < 4 and ("Count: " .. tostring(count)) or nil)
        if height >= 6 then
            frame.line(painter, 2, "WORK", theme.muted)
            frame.line(painter, 3, "Count: " .. tostring(count), theme.text)
            frame.line(painter, 4, saved == nil and "Saved: —" or ("Saved: " .. tostring(saved)), theme.muted)
        elseif height >= 4 then
            frame.line(painter, 2, "Count: " .. tostring(count), theme.text)
        end
        if height >= 3 then
            frame.footer(painter, "Status: " .. status, HINTS, nil, {
                {kind = "increment", key = "Enter", label = width >= 30 and "Add one" or "+1", enabled = true, primary = true},
                {kind = "exit", key = "Esc", label = "Exit", enabled = true},
            })
        end
        hits = painter.hits
        assert(output:present(frame.rows(painter)))
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
                local hit = frame.hit(hits, math.floor(tonumber(data.x) or 0), math.floor(tonumber(data.y) or 0))
                if hit and hit.kind == "increment" then increment()
                elseif hit and hit.kind == "exit" then running = false end
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
-- corpus document docs/application_contracts requires for an admitted, listed application,
-- and its identity follows the workspace-application naming rule, so the
-- example delivers to the author's own workspace unchanged.
M.OVERLAY_ID = "counter"
M.NAMESPACE = workspace_applications.NAMESPACE_ROOT .. "." .. M.OVERLAY_ID
M.TITLE = "Counter App"
M.VERSION = "1.0.0"

function M.example(): {{[string]: unknown}}
    return {{id = "app.counter:app", kind = "process.lua",
        data = {source = M.SOURCE, method = "main",
            modules = {"tty", "process", "channel", "json"},
            imports = {client = "bee.app:client", appearance = "bee.ui:appearance",
                frame = "bee.ui:frame"}},
        meta = {type = "bee.app", application = {api_version = 1, lifetime = "view",
            revision = "1", title = M.TITLE, instance_policy = "multiple",
            resume_schema = "guide-counter.v1", restart_policy = "automatic",
            menus = {"bee.shell:apps_menu"}}}}}
end

function M.example_json(): (string?, string?)
    return json.encode(M.example())
end

-- The example's test: one function.lua entry in the application's namespace.
M.TEST_SOURCE = [==[local test = require("test")

local function define_tests()
    test.describe("counter", function()
        test.it("adds one to a count", function()
            test.eq(1 + 1, 2)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
]==]

function M.test_example(): {{[string]: unknown}}
    return {{id = M.NAMESPACE .. ":counter_test", kind = "function.lua",
        data = {source = M.TEST_SOURCE, method = "run", imports = {test = "wippy.test:test"}},
        meta = {type = "test", suite = M.OVERLAY_ID}}}
end

-- The example application's own database: the capability request, its first
-- migration, and the tools that keep and list counts in it, so the person's
-- UI and an agent share one table.
M.DATABASE_NAME = "counts"
M.MIGRATION_SOURCE = [==[return require("migration").define(function()
    migration("Create counts", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute("CREATE TABLE counts (value INTEGER NOT NULL)")
                if err then error(err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS counts")
                if err then error(err) end
            end)
        end)
    end)
end)
]==]
M.COUNTS_SOURCE = [==[local funcs = require("funcs")
local sql = require("sql")

local function database()
    local reply = funcs.call("bee.gov.binding:granted_resources", {})
    local id = type(reply) == "table" and reply.ok == true and reply.value.databases.counts or nil
    if not id then return nil, "the counts database is not granted" end
    return sql.get(id)
end

local function record(arguments)
    local db, err = database()
    if not db then return {ok = false, error = {code = "UNAVAILABLE", message = tostring(err)}} end
    local _, insert_error = db:execute("INSERT INTO counts (value) VALUES (?)", {arguments.value})
    db:release()
    if insert_error then return {ok = false, error = {code = "FAILED", message = tostring(insert_error)}} end
    return {ok = true, value = {recorded = arguments.value}}
end

local function list()
    local db, err = database()
    if not db then return {ok = false, error = {code = "UNAVAILABLE", message = tostring(err)}} end
    local rows, query_error = db:query("SELECT value FROM counts ORDER BY rowid")
    db:release()
    if not rows then return {ok = false, error = {code = "FAILED", message = tostring(query_error)}} end
    local values = {}
    for index, row in ipairs(rows) do values[index] = row.value end
    return {ok = true, value = {counts = values}}
end

return {record = record, list = list}
]==]

function M.database_example(): {{[string]: unknown}}
    return {
        {id = M.NAMESPACE .. ":database", kind = "ns.requirement",
            meta = {value_kind = "security.policy", capability = "app.database",
                parameters = {name = M.DATABASE_NAME}, reason = "Keep the counts the counter saves"},
            data = {targets = {{entry = M.NAMESPACE .. ":app", path = ".security.policies +="}}}},
        {id = M.NAMESPACE .. ":agent_tools", kind = "ns.requirement",
            meta = {value_kind = "security.policy", capability = "agent.tools",
                parameters = {tools = {M.NAMESPACE .. ":count_list", M.NAMESPACE .. ":count_record"}},
                reason = "Let agents read and record counts"},
            data = {targets = {{entry = M.NAMESPACE .. ":app", path = ".security.policies +="}}}},
        {id = M.NAMESPACE .. ":create_counts", kind = "function.lua",
            meta = {type = "migration", target_db = M.DATABASE_NAME, ordinal = 1},
            data = {source = M.MIGRATION_SOURCE, method = "run", imports = {migration = "wippy.migration:migration"}}},
        {id = M.NAMESPACE .. ":count_record", kind = "function.lua",
            meta = {type = "tool", llm_alias = "counter_record", llm_description = "Record one count in the counter's database",
                input_schema = '{"type":"object","additionalProperties":false,"required":["value"],"properties":{"value":{"type":"integer"}}}',
                mcp = {annotations = {readOnlyHint = false, idempotentHint = false}}},
            data = {source = M.COUNTS_SOURCE, method = "record", modules = {"funcs", "sql"}}},
        {id = M.NAMESPACE .. ":count_list", kind = "function.lua",
            meta = {type = "tool", llm_alias = "counter_list", llm_description = "List the counts the counter keeps",
                input_schema = '{"type":"object","additionalProperties":false,"properties":{}}',
                mcp = {annotations = {readOnlyHint = true}}},
            data = {source = M.COUNTS_SOURCE, method = "list", modules = {"funcs", "sql"}}},
    }
end

-- How an application keeps its own data.
function M.database(): string
    return "An application keeps its data in its own database. Request it with an ns.requirement whose meta names"
        .. " value_kind security.policy, capability app.database, parameters {name = <database name>} and a reason,"
        .. " targeting the application at .security.policies +=. Create and change its tables with migrations:"
        .. " each is a function.lua entry with meta.type migration, meta.target_db equal to that database name and"
        .. " meta.ordinal, data.method run and the import migration = wippy.migration:migration; its source returns"
        .. " require(\"migration\").define(function() migration(\"<what it does>\", function() database(\"sqlite\","
        .. " function() up(function(db) ... end) down(function(db) ... end) end) end) end). Ordinals are append-only:"
        .. " a later version keeps every earlier migration unchanged and adds the next ordinal; an applied migration"
        .. " never runs again and changing or removing one is refused. The person approves the database and every"
        .. " migration a version runs in Needs you; Bee installs the database, runs the migrations once, then opens"
        .. " the application. At run time call bee.gov.binding:granted_resources and open databases[<name>] with"
        .. " sql.get, from the application and from its agent tools alike, so the person and agents work on the same"
        .. " tables. The example (include_example) carries database_entries_json: the counter's counts database, its"
        .. " first migration and the agent tools that record and list counts."
end

local DELIVERY_STEPS = {"approve it in Needs you, which opens on the person's desktop and lists the permissions and database migrations it adds",
    "Bee installs it once approved; Library shows installed versions and their history", "open it from Start, Apps"}

-- The steps a person takes after an agent requests delivery. Exposed so the
-- delivery tool and the guide cannot disagree about who does what.
function M.delivery_steps(source_overlay_id: string?): ({string}, string)
    local copied: {string} = {}
    for index, step in ipairs(DELIVERY_STEPS) do copied[index] = step end
    if drivers.name(source_overlay_id) then
        copied[#copied] = "open Sessions, press N and select the new driver; E customizes a saved copy"
        return copied, "Sessions"
    end
    return copied, "Start, Apps"
end

-- Guide sections, each readable alone. The index names them; a section read
-- returns one section; the example travels only on explicit request so a
-- guide read stays small.
function M.pack_shape(): string
    return "A component pack is one frozen file, " .. M.ENTRIES_PATH
        .. ", holding a JSON list of complete native registry entries. Each entry has id, kind,"
        .. " an optional meta and a required data; put source, method, modules and imports inside data."
        .. " Source is inline Lua text, never a file URL. Top-level YAML shorthand is not the registry API."
end
function M.pack_contents(): string
    return "A pack may contain process.lua applications, function.lua tools, library.lua support code,"
        .. " registry.entry declarations and security.policy entries. Installed metadata describes a capability;"
        .. " it never grants that capability. The destination separately constrains namespaces, entry kinds,"
        .. " native modules, policy grants and resource bindings during preflight, and the activation owner alone"
        .. " applies the reviewed overlay. Use the read-only components tool to inspect the effective installed"
        .. " registry and exact Hub package entries, documentation and examples before authoring."
        .. " Hub packages of type application, declaring bee.app or requesting capabilities install through the"
        .. " Library's governed stage, preflight, person approval and activation path. Their app.database grants"
        .. " provision dedicated databases, their migrations run against those databases, and agent.tools grants"
        .. " expose their tools. ns.definition is package metadata admitted by the package ceiling."
        .. " While you work, request_capability asks the person in Needs you for one catalog capability for this"
        .. " attempt and a bounded time: process.exec to run one exact command in a folder of this workspace, or"
        .. " http.api to reach one https origin under a path prefix with named methods. Poll capability_status"
        .. " with the approval_id; once it reports granted, call process_run (your arguments follow the approved"
        .. " command) or http_request with that approval_id until it expires."
end
function M.application_shape(): string
    return "An application is one process.lua entry with meta.type bee.app and a"
        .. " meta.application record declaring api_version 1, lifetime view, a nonempty revision and title,"
        .. " and instance_policy singleton or multiple, and menus listing the bee.menu entries it appears in:"
        .. " bee.shell:apps_menu places it in the Start panel's Apps menu, the way the person opens it."
        .. " Preflight reports APPLICATION_MENU for an application that names no menu."
        .. " Metadata describes the application; it never"
        .. " authorizes it. The host separately admits the definition, and the broker lists it only once"
        .. " the effective catalog carries it. Advance the application revision whenever executable source"
        .. " or configuration changes; a revision identifies one exact runnable definition."
        .. " Use restart_policy never for an app without checkpoints; automatic or manual requires"
        .. " a nonempty resume_schema of at most 80 characters without control characters. Preflight"
        .. " reports APPLICATION_CHECKPOINT when this metadata prevents the desktop from opening it."
end
function M.rendering(): string
    return "The process entry carries its Lua source inline and renders with the terminal"
        .. " toolkit: tty.events, tty.start, tty.surface, tty.screen_size, tty.canvas with one-based"
        .. " canvas:put, output:present, client.launch, client.ready, and client.checkpoint when the"
        .. " metadata declares a resume_schema. Draw every frame through bee.ui:frame, the"
        .. " toolkit Bee's own applications use: frame.new, then frame.header for the uppercase title"
        .. " and a muted summary, frame.tabs, frame.table or frame.row for selectable rows (a › marker"
        .. " shows selection without color), frame.empty for an empty or failed list with its next"
        .. " action, frame.footer with one primary button and secondary buttons at the left on"
        .. " the final row and frame.hints key help at the right; hints give way to actions. Status appears above; resolve mouse input with"
        .. " frame.hit over the hits the frame recorded. Use semantic appearance roles from"
        .. " bee.ui:appearance, authenticate appearance messages by their broker sender, and"
        .. " declare exactly the native modules and library imports the source uses."
end
function M.transport(): string
    return "Guide and source name no overlay_id; other authoring operations name an overlay_id; list without one returns only overlays owned by this caller. The overlay_id is distinct from the agent's runtime workspace."
        .. " An MCP put carries at most 65,536 decoded bytes of one file. For a larger entries.json,"
        .. " put the first chunk, then append chunks of at most 65,536 bytes. Each append supplies"
        .. " the current expected_revision, a new idempotency_key, offset equal to the current file"
        .. " byte length. The owner computes the resulting file's SHA-256 digest; a put or an append"
        .. " may assert it with result_digest, a lowercase digest. A mismatch changes nothing. Read/list"
        .. " show the resulting byte count and digest."
        .. " Each file remains bounded to 4 MiB, and the overlay to 16 MiB. Read returns a base64"
        .. " window of up to 16,384 bytes with offset, chunk_bytes and eof; page with offset and limit."
        .. " Freeze copies the complete measured file set into owned storage and binds it to"
        .. " the overlay identity and revision; it does not change the edit revision, and later edits"
        .. " cannot change a frozen snapshot. Freeze is not approval, installation or execution."
end
function M.after_freeze(): string
    return "After freeze, publication prepare parses " .. M.ENTRIES_PATH
        .. " from that exact snapshot into the canonical artifact (" .. M.SCHEMA
        .. "). Requesting delivery stages the version at this destination and reads its preflight verdict;"
        .. " a refusal names the diagnostic and its remedy. A person-confirmed Settings edit grant uses its"
        .. " exact namespace as overlay_id and source_overlay_id. Publication derives that source and overlay"
        .. " owner from the existing activation profile and refuses an expired grant. Then a person must " .. join(DELIVERY_STEPS)
        .. ". Only the activation owner may write an overlay. A pack may append migration functions for an"
        .. " existing host-admitted database when every imported dependency is already installed and no"
        .. " auto-start consumer is present. Governance seals the exact functions and runs them before exposing"
        .. " the complete overlay. New databases, changed applied migrations and schema rollback are refused."
end
function M.driver_delivery(): string
    return drivers.RULE .. "."
        .. " Read a CLI script with overlay operation source and its absolute path or a path relative to"
        .. " the authenticated workspace folder (no overlay_id); use a relative path for a project-relative root. Source returns a base64 window,"
        .. " window_digest, next_offset and eof; page with offset and limit up to 16384."
        .. " It refuses private paths, foreign folders and workspaces without their own filesystem root."
        .. " Inspect the installed bee/driver package docs and built-in driver entries with components."
        .. " Author entries.json, freeze and request delivery with source_overlay_id driver.<name>."
        .. " Delivery asks the person once in Needs you; approving it applies the exact candidate."
        .. " No application admission or automatic start is created."
        .. " A custom external CLI binding uses bee.driver:driver prepare, dispatch, normalize and configure"
        .. " functions in .binding, and bee.driver:locate_facet locate. Its meta.type is harness.driver with"
        .. " driver_id, descriptor_ref and profiles_ref. Declare a harness.profile record whose driver_ref"
        .. " matches. A CLI descriptor uses bee.driver.cli-descriptor@3 and a supported codec."
        .. " Select the shared implementation with universal.prepare/dispatch/normalize/locate(descriptor_ref)"
        .. " and universal.protocol(descriptor_ref), importing bee.driver.binding:universal."
        .. " For a CLI requiring no gateway/provider configuration, configure uses"
        .. ' universal.configure("plain", {plain = function(_: unknown): {[string]: unknown}'
        .. " return {ok = true, delivery = {files = {}, arguments = {}}} end}, descriptor_ref)"
        .. " with descriptor configure plain. These factories bind the owned descriptor; do not copy the codec."
        .. " A .security:descriptor_read policy may grant only registry.get and registry.snapshot;"
        .. " function data.security.policies names it when descriptor access is needed."
        .. " Add an ns.requirement in .binding with meta.value_kind contract.binding, data.default your own"
        .. " harness binding ID and one data.targets entry {entry = bee.harness.launch:harness_activation,"
        .. " path = .bindings +=}. This append is the only allowed host target; all targets must exist."
        .. " In .profiles declare a bee.launch_definition with binding_ref and profile_id naming the window profile."
        .. " Set presentation.start_menu = true so the person can select it in Sessions (N opens the agent picker)."
        .. " A false value keeps the definition programmatic and hides it from this picker, including saved copies."
        .. " Use default_mode window and list in docker_credentials the login a Docker placement needs."
        .. " Set session_resource = session in the launch definition: the host's existing retained session"
        .. " resource is required to open Sessions. This name selects an existing host resource;"
        .. " do not create a resource entry, database or alternative session store."
        .. " Select an owned bee.launch_policy in policy_ref with the reviewed executable mapping,"
        .. " private HOME, no credentials for an account-free CLI and native placement."
        .. " Inspect built-in definitions and policies for their required schema fields."
        .. " Keep credentials, gateway tools and host HOME absent unless separately admitted by the host."
        .. " After approval settles, open Sessions, press N and select the new driver to open an idle session."
        .. " The CLI opens in its window. E customizes a saved copy of the selected definition."
        .. " Existing sessions retain their pinned routes; new sessions use the new binding."
end

-- How an application ships tests and runs them in the node.
function M.tests(): string
    return "An application's tests ship in its own pack: a function.lua entry associated with the application by registry ownership or meta.application, with"
        .. " meta.type test, an optional meta.suite that groups it and an optional meta.timeout such as 30s that"
        .. " bounds the one test (30s by default), method run and the import test = wippy.test:test. Its source"
        .. " describes cases with test.describe and test.it, asserts with test.eq, test.neq, test.is_true,"
        .. " test.is_false, test.is_nil, test.not_nil, test.contains and test.throws, builds them with"
        .. " local cases = test.run_cases(define_tests) and returns {run = function(options) return cases(options) end};"
        .. " run passes its options on, because they say where the results go. Keep the logic worth testing in a"
        .. " library.lua entry of the pack that the application and the test both import. After the person approved"
        .. " the delivery, call the tests tool: list names the application's tests, run starts a run and returns its"
        .. " run_id at once (filter keeps tests whose id contains it), and status with that run_id returns progress and,"
        .. " when complete, each test's cases with pass, fail or skip, the error and the duration. Name the application by"
        .. " its definition id, or its owned overlay id for authored delivery. Hub-installed applications are admitted by"
        .. " the host's governed delivery association; discovery never matches namespaces. A test runs inside the node as"
        .. " your application, with the scope the person approved for it and no more, so a case that needs a module or"
        .. " grant the application lacks fails with a denial; change the application and deliver again. Only the delivered"
        .. " version has tests to run: change, freeze and deliver again to test new code."
end

-- How an application offers tools agents call on the same state its
-- terminal UI shows the person.
function M.agent_tools(): string
    return "An application can offer agents tools that work on the same state its terminal UI shows the person."
        .. " Each tool is a function.lua entry in the application's namespace with meta.type tool, meta.llm_alias (the"
        .. " tool name agents call: letters, digits, _, . and -), meta.llm_description, meta.input_schema as a JSON"
        .. " object string, an optional meta.output_schema and optional meta.mcp.annotations (readOnlyHint,"
        .. " destructiveHint, idempotentHint, openWorldHint). It declares no security of its own: it runs as the"
        .. " application with exactly the grants the person approved for it, and returns {ok, value, error} where"
        .. " error is {code, message}. Read and write the application's state through its grants, for example the"
        .. " database bee.gov.binding:granted_resources names, so the UI and the agent see the same data. Request"
        .. " capability agent.tools with an ns.requirement whose meta.parameters is {tools = {<each tool function id>}},"
        .. " targeting the application at .security.policies +=; the person approves it in Needs you with the"
        .. " application's other grants. Schemas must stay in the subset Bee advertises (object schemas with typed"
        .. " properties, required, enum, const, bounds, formats, nested objects and arrays, oneOf/allOf/if/then/else/not);"
        .. " preflight refuses a tool that is not this pack's own, uses another schema, declares security or shares an"
        .. " alias. An agent reaches the tools through app_tools once the person enabled it in the agent's profile or"
        .. " approved bee.app:tools as session access: app_tools lists the offered tools and why any is not offered,"
        .. " and each offered tool is called by its alias like any other tool. Arguments and replies are checked"
        .. " against the declared schemas. A tool disappears when its application or grant does; calling it then"
        .. " answers TOOLS_CHANGED, and two applications offering one alias offer neither."
end

function M.sharing(): string
    return "A person shares an installed application made on their bee through the Library."
        .. " Hive Sync delivers immutable versions as inert replicas; ownership is the exact"
        .. " {source_node, source_workspace, component} identity, never a namespace."
        .. " On the destination, following is off by default. The person chooses Install & follow"
        .. " during installation or Follow source later in the Library's version details."
        .. " The serialized Governance worker stages and preflights a newer verified publication"
        .. " and reuses its installed approval only for equal or narrower authority without pending migrations."
        .. " Expanded permissions, exposure, audiences or caller mappings, and migrations ask once in Needs you;"
        .. " a general grant lease does not bypass this decision. Pause updates and Pin version stop following;"
        .. " going back pins, and removal turns following off. The Library shows the state and last outcome."
        .. " Durable cursors and activation receipts resume after restart; rollback and equivocation are refused,"
        .. " and failed updates retain the working version. Following grants no source-side automatic-publication"
        .. " permission: every bee authorizes its own publication and activation independently."
end

type Section = {id: string, title: string, body: fun(): string}
function M.hive_sdk_example(node: string, workspace: string, audience: string): {{[string]: unknown}}
    return hive_sdk_example.entries(node, workspace, audience)
end

function M.hive_sdk(): string
    return "Build a project test SDK as an admitted app, an agent.trait, local tools and explicit Hive operations."
        .. " The complete entries.json below uses overlay test_sdk and namespace app.test_sdk. Replace runner-node,"
        .. " destination-workspace and author-node with the actual authenticated nodes and destination workspace"
        .. " the person approves. agent.tools offers only the named functions. hive.expose requests destination-local"
        .. " approval for each operation and authenticated peer audience; open still requires live admission and"
        .. " that approval. hive.call bounds nodes, workspaces, application addresses, services and operations."
        .. " App code imports bee.hive:hive and calls hive.call without added registry, system or supervisor-lookup grants."
        .. " An open audience approves a peer node, not a source app; the existing app base permits process messages."
        .. " The facade bounds its own calls. The peer tool runs as the source application; run executes as the"
        .. " destination copy with its own grants."
        .. "\n\nUse a source identity"
        .. ' {source_node = "author-node", source_workspace = "test_sdk", component = "app.test_sdk"}'
        .. " or an approved alias when copies use different definition IDs. Grant that exact address in hive.call"
        .. " too. A version is not part of the application address. Discovery uses live metadata and ownership."
        .. "\n\napp_tools with node lists only peer agent tools exposed to this node. Call a listed peer tool with"
        .. " operation call, node, tool and arguments. Direct aliases and omitted node remain local. For associated"
        .. " exposed tests, use tests with operation list, application and node; then run with a stable"
        .. " idempotency_key; then status with the run_id and the same node. Remote test runs reuse the existing"
        .. " runner and recheck live exposure."
        .. "\n\nDeclare effect read for pure computation; omission defaults to mutation. A mutation requires a"
        .. " bounded idempotency_key. Retry identical arguments and the same key: durable destination receipts"
        .. " replay completion and refuse changed arguments. A timeout means outcome unknown; the deadline bounds"
        .. " waiting and does not roll back effects. Pending or interrupted receipts never redispatch."
        .. "\n\nPublish an immutable version, stage it independently at each destination, read preflight diagnostics"
        .. " and ask for that destination's approval before application. New versions repeat that workflow."
        .. " Governance can reuse installed approval when authority does not widen and no pending migrations remain;"
        .. " that reuse does not follow publications automatically. Automatic follow_source consent and reconciliation"
        .. " are unavailable. Policy mode stays fail-closed until trusted subject"
        .. " mappings exist; this example uses open with exact audiences. Package operations without an installed"
        .. " overlay stay fail-closed. Legacy service routes retain their destination owner authorization and are"
        .. " outside the app facade. To test a real checkout, add separately approved workspace.files.read and"
        .. " process.exec requirements and use their granted host functions."
        .. "\n\nThis project's executable pure Lua configuration multiplies {1,2,3} by three for ci and returns 18"
        .. " from the destination worker, including its PID. The two-node e2e proof verifies that worker runs on"
        .. " beta while the calling application's peer tool runs on alpha."
        .. "\n\nentries.json (freeze this complete JSON list):\n"
        .. assert(json.encode(M.hive_sdk_example("runner-node", "destination-workspace", "author-node")))
end

function M.hive_sessions(): string
    return "The person allows cross-bee agents at the receiving bee in Sessions (A: Allowances), or answers the first"
        .. " Needs you request there. Scopes are list only; message and await; or open new sessions. Consent has a"
        .. " duration or is permanent, is workspace-bound and is revocable. Hive membership grants no agent access."
        .. " Every Sessions contract operation and catalog list accepts optional node; omission keeps local behavior."
        .. " Import bee.threads.sessions.client:sessions and bind sessions.client{node = \"bee-peer\"}; returned handles"
        .. " keep that bee. The existing ten MCP session_* tools accept node too. Apps use bee.hive:hive through"
        .. " their session grants. Sessions operations have registry-declared policy exposure and receiver-owned"
        .. " peer mapping. Mutations keep an explicit operation_key; hive.call idempotency_key equals that key."
        .. " Threads commits peer work with inbox request/reply records and in_reply_to correlation. Await reads"
        .. " its durable node-qualified WorkRef. Transport timeout means UNKNOWN_OUTCOME and identical-key recovery;"
        .. " an observation's pending timeout does not stop work. See corpus docs/hive_sessions for the complete workflow."
end

local SECTIONS: {Section} = {
    {id = "pack", title = "Component pack shape", body = function(): string return M.pack_shape() end},
    {id = "contents", title = "Pack contents and authority", body = function(): string return M.pack_contents() end},
    {id = "application", title = "Application entries", body = function(): string return M.application_shape() end},
    {id = "rendering", title = "Rendering with the terminal toolkit", body = function(): string return M.rendering() end},
    {id = "style", title = "Visual style and archetypes", body = function(): string return M.visual_style() end},
    {id = "config", title = "Configuration shapes", body = function(): string return CONFIG_SHAPE_RULE end},
    {id = "transport", title = "Overlay transport, freeze", body = function(): string return M.transport() end},
    {id = "delivery", title = "Delivery after freeze", body = function(): string return M.after_freeze() end},
    {id = "sharing", title = "Sharing applications", body = function(): string return M.sharing() end},
    {id = "tests", title = "Testing your application", body = function(): string return M.tests() end},
    {id = "database", title = "Your application's database", body = function(): string return M.database() end},
    {id = "agent_tools", title = "Tools agents call", body = function(): string return M.agent_tools() end},
    {id = "hive_sessions", title = "Agents across bees with receiving consent", body = function(): string return M.hive_sessions() end},
    {id = "hive_sdk", title = "A project test SDK across Hive nodes", body = function(): string return M.hive_sdk() end},
    {id = "workspace", title = "Delivering to your own workspace", body = function(): string return M.workspace_delivery() end},
    {id = "drivers", title = "Custom CLI drivers and source inspection", body = function(): string return M.driver_delivery() end},
    {id = "docs", title = "Platform documentation", body = function(): string return M.platform_documentation() end},
}
function M.section_list(): {{id: string, title: string}}
    local listed: {{id: string, title: string}} = {}
    for _, section in ipairs(SECTIONS) do listed[#listed + 1] = {id = section.id, title = section.title} end
    return listed
end
function M.section_text(id: string): string?
    for _, section in ipairs(SECTIONS) do if section.id == id then return section.body() end end
    return nil
end
-- The short index: revision, what an overlay is, section list and how to
-- read one section or the example. A full document is built only below.
function M.index(): string
    local lines: {string} = {}
    lines[#lines + 1] = "Bee component authoring guide (" .. M.REVISION .. ")"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "A component pack is one frozen file, " .. M.ENTRIES_PATH
        .. ", holding a JSON list of complete native registry entries."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Sections:"
    for _, section in ipairs(SECTIONS) do lines[#lines + 1] = "  " .. section.id .. ": " .. section.title end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Read one section with section set to its id. Request the minimal working"
        .. " example separately with include_example set; it carries the entries JSON inline."
    return table.concat(lines, "\n")
end
function M.document(): string
    local lines: {string} = {}
    lines[#lines + 1] = "Bee component authoring guide (" .. M.REVISION .. ")"
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.pack_shape()
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.pack_contents()
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.application_shape()
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.rendering()
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.visual_style()
    lines[#lines + 1] = ""
    lines[#lines + 1] = CONFIG_SHAPE_RULE
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.transport()
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.after_freeze()
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.tests()
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.workspace_delivery()
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.driver_delivery()
    lines[#lines + 1] = ""
    lines[#lines + 1] = M.platform_documentation()
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Minimal example: create overlay " .. M.OVERLAY_ID .. ", put the JSON below at path "
        .. M.ENTRIES_PATH .. " and freeze it. Its entry id is " .. assert(workspace_applications.application(M.example())) .. " and its title " .. M.TITLE .. "."
    return table.concat(lines, "\n")
end

-- How an application reaches the author's own workspace: the naming rule the
-- host's workspace-application profile admits and the delivery request.
function M.workspace_delivery(): string
    return "To deliver an application to your own workspace, " .. workspace_applications.RULE .. "."
        .. " This workspace admits exactly that namespace, the entry kinds and native modules its host"
        .. " profile names and the ordinary application boundary; a candidate outside it is refused at"
        .. " preflight with the remedy. Freeze, then call the delivery tool with operation request, your"
        .. " source_overlay_id, a version and the frozen snapshot_digest; workspace_id defaults to your"
        .. " own workspace. A later version is a new freeze and a new delivery request with a higher version."
        .. " Request a host catalog capability with an ns.requirement entry whose meta names value_kind"
        .. " security.policy, the capability, its parameters and a reason, targeting your application entry at"
        .. " .security.policies +=; the person approves it at installation. For contract.call,"
        .. ' meta.parameters is {binding = "bee.threads.sessions.binding:catalog_binding", methods = {"list"}}'
        .. " when requesting the Sessions catalog binding. The binding and method names are exact;"
        .. " check the destination's bee.capability:catalog with the components tool for its admitted parameters."
        .. " To run a host program, request process.exec with"
        .. ' meta.parameters {command = "/usr/bin/make test", directory = "."}: command is the executable, an'
        .. " absolute path or a name on the host PATH, followed by any fixed leading arguments, and directory a"
        .. " folder relative to your workspace. The person sees that exact command and folder in Needs you and"
        .. " approves it explicitly; the app may then run the command alone or followed by further arguments, in"
        .. " that folder, with no environment of its own. To reach a web API, request http.api with an https"
        .. " origin, methods and a path_prefix. A native module outside the profile is admitted only together"
        .. " with the capability that authorizes it: declare the exec module with an approved process.exec"
        .. " request, and the contract module with an approved contract.call or agents.launch request;"
        .. " preflight reports MODULE_DENIED naming the capability to request otherwise. At run time, call"
        .. " bee.gov.binding:granted_resources for the identities of your granted file volumes (by subpath),"
        .. " database (by name) and executors (by command, then directory) and pass that executor to exec.get;"
        .. " make approved contract calls and HTTP requests through"
        .. " bee.gov.binding:contract_call and bee.gov.binding:http_request; never embed a grant identity."
end

-- The application archetypes of corpus document docs/app_style: the request each
-- one answers and the frame and visualization kit calls that compose it.
type Archetype = {name: string, request: string, calls: {string}}
local ARCHETYPES: {Archetype} = {
    {name = "list and detail", request = "a collection of items to browse, select and act on",
        calls = {"frame.table", "frame.window", "frame.split", "frame.panel"}},
    {name = "dashboard grid", request = "several independent measurements at once",
        calls = {"frame.grid", "frame.panel", "viz.tiles", "viz.bars", "viz.line", "viz.gauge"}},
    {name = "form", request = "values the person enters or edits", calls = {"frame.field", "frame.footer"}},
    {name = "wizard", request = "a task done in ordered steps", calls = {"frame.steps", "frame.field", "frame.footer"}},
    {name = "log and stream", request = "an append-only sequence of lines or events",
        calls = {"frame.row", "frame.window", "viz.series"}},
    {name = "monitor", request = "a measurement that changes over time",
        calls = {"viz.tiles", "viz.line", "viz.series", "viz.cadence", "frame.table"}},
}
M.ARCHETYPES = ARCHETYPES

-- How an application looks: the style contract, the size classes, the
-- archetype for a request and the visualization kit.
function M.visual_style(): string
    local routes: {string} = {}
    for _, archetype in ipairs(ARCHETYPES) do
        routes[#routes + 1] = archetype.name .. ": " .. archetype.request .. " (" .. table.concat(archetype.calls, ", ") .. ")"
    end
    return "Read the visual style, corpus document docs/app_style, before drawing:"
        .. " it fixes the rows, gaps, color roles, states and mouse targets, and every rule names its frame call."
        .. " Layouts change only at the size classes frame.size reports, compact from 80x24, standard from 120x36"
        .. " and wide from 160x48, and frame.layout returns the header, tabs, work and shared footer rows."
        .. " Pick the archetype that matches the request and compose it from its calls, so even a complex"
        .. " dashboard is a one-shot composition: " .. table.concat(routes, "; ") .. "."
        .. " Chart with the visualization kit bee.ui.viz:viz, imported as viz = \"bee.ui.viz:viz\":"
        .. " viz.sparkline, viz.line (area too), viz.bars, viz.columns, viz.stacked, viz.histogram, viz.heatmap,"
        .. " viz.waffle, viz.gauge, viz.progress, viz.tiles, viz.bar_cell, viz.timeline and viz.graph, with viz.series"
        .. " rings and a viz.cadence for live data. Compose a dashboard from those calls; the toolkit document"
        .. " shows every kit call with a tested example and its screen."
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
        .. table.concat(M.CROSS_NODE_TOPICS, ", ") .. " topics for hive, subscriptions and placement. Read the matches."
        .. " Corpus document docs/hive_test_sdk teaches the complete app, trait and tools workflow."
        .. " The authored UI rules are corpus document docs/ui_brand_book, and the toolkit reference gives compact"
        .. " examples built on bee.ui:frame. For"
        .. " a terminal UI, search the " .. table.concat(M.TERMINAL_TOPICS, ", ")
        .. " topics for the toolkit, layout, styles and input. Read the guide once, then look every"
        .. " question up in the corpus rather than guessing a signature."
end

-- The value the MCP overlay tool returns for its read-only guide operation.
-- A bare guide read returns the short index with the section list. One
-- section travels when section names it; the worked example, which embeds the
-- entries JSON and its Lua source twice, travels only on explicit request.
function M.value(request: {[string]: unknown}?): {[string]: unknown}
    local section_id: string? = nil
    local include_example = false
    if request ~= nil then
        if type(request.section) == "string" then section_id = request.section end
        if request.include_example == true then include_example = true end
    end
    if section_id ~= nil then
        local text = M.section_text(section_id)
        if not text then return {revision = M.REVISION, error = {code = "NOT_FOUND",
            message = "unknown guide section " .. section_id, remedy = "read the guide index for section ids"}} end
        return {revision = M.REVISION, section = section_id, text = text, sections = M.section_list()}
    end
    if not include_example then
        return {revision = M.REVISION, document = M.index(), sections = M.section_list()}
    end
    local encoded, encode_error = M.example_json()
    if not encoded then return {revision = M.REVISION, document = M.index(), sections = M.section_list(),
        example_error = tostring(encode_error)} end
    local test_encoded, test_error = json.encode(M.test_example()[1])
    if not test_encoded then return {revision = M.REVISION, document = M.index(), sections = M.section_list(),
        example_error = tostring(test_error)} end
    local database_encoded, database_error = json.encode(M.database_example())
    if not database_encoded then return {revision = M.REVISION, document = M.index(), sections = M.section_list(),
        example_error = tostring(database_error)} end
    return {revision = M.REVISION, document = M.index(), sections = M.section_list(),
        example = {path = M.ENTRIES_PATH, entries_json = encoded, definition_id = "app.counter:app",
            title = M.TITLE, version = M.VERSION, source = M.SOURCE,
            test_entry_json = test_encoded, test_entry_id = M.test_example()[1].id,
            database_entries_json = database_encoded}}
end

return M
