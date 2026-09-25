-- MIT. Actual broker publication/revocation proof; all registry writes are fixture-owned.
local process = require("process")
local channel = require("channel")
local time = require("time")
local security = require("security")
local registry = require("registry")
local tty = require("tty")
local decode = require("decode")
local appearance = require("appearance")
local logger = require("logger")
type Principal = {actor_id: string, workspace_id: string, definition_id: string, definition_revision: string,
    execution_generation: integer, launch_generation: integer, thread_id: string?}
local function run()
    local owner = tostring(process.pid())
    local workspace = "0123456789abcdef0123456789abcdef"
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local principals = assert(process.listen("bee.admission_probe.principal", {message = true}))
    local scope = security.new_scope({assert(security.policy("bee.security.desktop:broker_policy")), assert(security.policy("bee.security:core_spawn_boundary"))})
    local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = workspace})
        :with_scope(scope):spawn_monitored("bee.applications:broker", "bee:workers", owner, appearance.defaults())))
    local function catalog_contains(expected: boolean)
        local selected = channel.select({catalogs:case_receive(), time.after("5s"):case_receive()})
        assert(selected.ok and selected.channel == catalogs, "Catalog refresh timed out")
        local message = selected.value
        assert(message:from() == broker)
        local value: unknown = message:payload():data()
        assert(type(value) == "table" and type(value.items) == "table")
        local found = false
        for _, item in ipairs(value.items) do
            if type(item) == "table" and item.definition_id == "bee.admission_probe:app" then found = true end
        end
        assert(found == expected, "Wrong admitted catalog")
    end
    local function reply(id: string): decode.Reply
        local deadline = time.after("5s")
        while true do
            local selected = channel.select({replies:case_receive(), deadline:case_receive()})
            assert(selected.ok and selected.channel == replies, "Broker reply timed out: " .. id)
            local message = selected.value
            assert(message:from() == broker)
            local value = assert(decode.reply(message:payload():data()))
            assert(value.op ~= "closed" or id == "shutdown", "Live app stopped during admission refresh")
            if value.request_id == id then return value end
        end
        error("Reply channel closed")
    end
    local function open(id: string, thread_id: string?): decode.Reply
        assert(process.send(broker, "bee.app.request", {version = 1, workspace_id = workspace,
            request_id = id, op = "open", definition_id = "bee.admission_probe:app", thread_id = thread_id}))
        return reply(id)
    end
    local function principal(): Principal
        local selected = channel.select({principals:case_receive(), time.after("5s"):case_receive()})
        assert(selected.ok and selected.channel == principals, "Application principal report timed out")
        local value: unknown = selected.value:payload():data()
        assert(type(value) == "table", "Application principal report was malformed")
        assert(type(value.actor_id) == "string" and type(value.workspace_id) == "string"
            and type(value.definition_id) == "string" and type(value.definition_revision) == "string"
            and type(value.execution_generation) == "number" and value.execution_generation == math.floor(value.execution_generation),
            "Application principal report was malformed")
        assert(type(value.launch_generation) == "number" and value.launch_generation == math.floor(value.launch_generation),
            "Application launch generation was malformed")
        if value.thread_id ~= nil and type(value.thread_id) ~= "string" then error("Application thread identity was malformed") end
        return {actor_id = value.actor_id, workspace_id = value.workspace_id, definition_id = value.definition_id,
            definition_revision = value.definition_revision, execution_generation = math.floor(value.execution_generation),
            launch_generation = math.floor(value.launch_generation), thread_id = value.thread_id}
    end
    local function publish(bindings: unknown)
        local snapshot = assert(registry.snapshot())
        local entry = assert(snapshot:get("bee.security:application_admission"))
        entry.data = {bindings = bindings}
        local changes = snapshot:changes()
        changes:update(entry)
        assert(changes:apply())
    end
    catalog_contains(false)
    assert(open("unbound").error_code == "not_admitted", "Metadata authorized an unbound app")
    assert(process.send(broker, "bee.app.request", {version = 1, workspace_id = workspace,
        request_id = "bind", op = "bind", recipient = owner}))
    assert(reply("bind").error_code == "")
    publish({{definition_id = "bee.admission_probe:app", policies = {"bee.admission_probe:grant"}}})
    catalog_contains(true)
    local first = open("admitted", "admission-thread")
    assert(first.error_code == "", first.error)
    local retained = assert(tty.attach(first.mount))
    assert(table.concat(assert(retained:snapshot()).rows):find("GRANTED", 1, true), "Host-selected scope was not used")
    local first_principal = principal()
    assert(first_principal.actor_id == "bee.application:" .. workspace .. ":" .. first.instance_id, "Application actor ID was not host-derived")
    assert(first_principal.workspace_id == workspace and first_principal.definition_id == "bee.admission_probe:app"
        and first_principal.definition_revision == "1" and first_principal.execution_generation == 1,
        "Application actor metadata was not delivered")
    assert(first_principal.launch_generation == first_principal.execution_generation,
        "Application launch and actor generations diverged")
    assert(first.thread_id == "admission-thread" and first_principal.thread_id == "admission-thread",
        "Broker-selected thread identity was not delivered to the application")
    -- A valid replacement changes only future launches, not an existing scope.
    publish({{definition_id = "bee.admission_probe:app", policies = {}}})
    catalog_contains(true)
    local second = open("reduced")
    assert(second.error_code == "", second.error)
    local second_principal = principal()
    assert(second.thread_id == nil and second_principal.thread_id == nil, "Unbound open unexpectedly inherited a thread identity")
    local reduced = assert(tty.attach(second.mount))
    assert(table.concat(assert(reduced:snapshot()).rows):find("DENIED", 1, true), "Old scope cache survived replacement")
    assert(table.concat(assert(retained:snapshot()).rows):find("GRANTED", 1, true), "Refresh replaced an existing producer")
    publish({})
    -- Deliberately do not await the ticker: every new open revalidates admission.
    assert(open("revoked").error_code == "not_admitted", "Revoked binding still launched")
    catalog_contains(false)
    assert(retained:snapshot() and reduced:snapshot(), "Revocation killed running producers")
    publish({{definition_id = "bee.admission_probe:app", policies = {"bee.admission_probe:missing"}}})
    assert(open("invalid-policy").error_code == "not_admitted", "Invalid policy reused old grants")
    catalog_contains(false)
    publish({{definition_id = "bee.admission_probe:app", policies = {}}})
    catalog_contains(true)
    local recovered = open("recovered")
    assert(recovered.error_code == "", "Valid admission did not recover: " .. recovered.error_code .. " " .. recovered.error)
    publish({{definition_id = "bee.admission_probe:app", policies = {}, unknown_authority = true}})
    assert(open("malformed").error_code == "not_admitted", "Malformed binding reused old grants")
    catalog_contains(false)
    assert(retained:snapshot(), "Invalid declaration killed running producer")
    retained:close(); reduced:close()
    assert(process.send(broker, "bee.app.request", {version = 1, workspace_id = workspace,
        request_id = "shutdown", op = "shutdown"}))
    assert(reply("shutdown").error_code == "")
    process.terminate(broker)
    process.unlisten(replies); process.unlisten(catalogs); process.unlisten(principals)
    logger:info("BEE_APP_ADMISSION_COMPLETE")
end
local function main()
    local ok, problem = pcall(run)
    if not ok then logger:error("Admission probe failed", {error = tostring(problem)}); error(problem) end
end
return {main = main}
