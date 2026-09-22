-- Isolation proof for the threads module: only bee.threads namespaces plus
-- this host composition are loaded, the module's dependency interface has
-- been linked, and the journal works through its public contract.
local registry = require("registry")
local contract = require("contract")
local sql = require("sql")
local journal = require("journal")
local io = require("io")

local function main()
    local definition = assert(registry.get("bee.threads:definition"), "module definition missing")
    assert(definition.kind == "ns.definition", "definition kind")
    local requirement = assert(registry.get("bee.threads:target_db"), "target_db requirement missing")
    assert(requirement.kind == "ns.requirement", "requirement kind")
    local reference = assert(registry.get("bee.threads:database_ref"), "database_ref missing")
    assert(reference.data.resource_ref == "bee.threads:db", "target_db default was not linked into database_ref: " .. tostring(reference.data.resource_ref))

    for _, id in ipairs({"bee.application:appearance", "bee.host:main", "bee.console:app", "bee.workspace:main"}) do
        assert(registry.get(id) == nil, id .. " leaked into the threads closure")
    end

    local direct, direct_error = sql.get("bee.threads:db")
    assert(direct == nil and direct_error ~= nil, "caller gained SQL authority")

    local log = assert(journal.open("isolation"))
    assert(log:claim("run"))
    for i = 1, 3 do
        local result, err = log:append("run", "key-" .. tostring(i), "check", "{}")
        assert(result, err or "append failed")
        assert(result.seq == i, "sequence")
    end
    local page = assert(log:read_after(0))
    assert(#page.events == 3 and page.events[3].kind == "check", "replay")
    local binding = assert(contract.open("bee.threads:local"))
    local denied = binding:read_after({thread = "isolation", after = 0, actor = "someone-else"})
    assert(type(denied) == "table" and #denied.events == 3, "actor in payload changed identity")
    for _, id in ipairs({"bee.threads.records:types", "bee.threads.service:types", "bee.threads.persist:migrations"}) do
        local slice = assert(registry.get(id), id .. " missing")
        assert(slice.kind == "library.lua", id .. " kind")
    end
    local authority = assert(contract.open("bee.threads:authority_local"))
    local created = authority:create({thread_id = "isolation-rich", idempotency_key = "create-1", title = "Isolation"})
    assert(type(created) == "table" and created.ok == true, "authority create: " .. tostring(created and created.error and created.error.message))
    local recorded = authority:record({thread_id = "isolation-rich", idempotency_key = "record-1", kind = "message",
        body = {message_id = "m1", message_kind = "request", recipient_ids = {}, content = {text = "hello"}}})
    assert(recorded.ok == true and recorded.value.sequence == 1, "authority record: " .. tostring(recorded.error and recorded.error.message))
    local lifecycle = assert(contract.open("bee.threads:lifecycle_local"))
    local admitted = lifecycle:admit_action({thread_id = "isolation-rich", idempotency_key = "admit-1", action_id = "a1",
        admitted = {request_id = "q", principal_id = "threads-isolation", binding_ref = "b", binding_digest = "d", grant_refs = {}, budget_ref = "budget", input = {text = "go"}}})
    assert(admitted.ok == true and admitted.value.sequence == 2, "lifecycle admit: " .. tostring(admitted.error and admitted.error.message))
    local page = authority:read_after({thread_id = "isolation-rich", cursor = 0})
    assert(page.ok == true and #page.value.records == 2 and page.value.records[2].kind == "action.admitted", "authority read_after")
    local ledger = sql.get("bee.threads:db")
    assert(ledger == nil, "caller gained SQL authority")
    io.print("threads module: definition, linked target_db, isolated closure, journal contract, authority and lifecycle contracts")
end
return {main = main}
