-- MIT. Real scoped facade -> worker -> registry dependency-root lifecycle.
local funcs = require("funcs")
local registry = require("registry")
local security = require("security")
local logger = require("logger")
local bounds = require("bounds")
type Object = {[string]: unknown}
local function call(operation: string, request: unknown?, digest: string?): Object
    local result, problem = funcs.new():call("bee.hub.binding:call", {operation = operation, request = request, expected_digest = digest})
    assert(not problem, tostring(problem))
    local reply = bounds.object(result)
    assert(reply, "invalid facade result")
    return reply
end
local function prepare(request: unknown): string
    local reply = call("plan", request)
    assert(reply.ok == true, "plan failed: " .. tostring(reply.message))
    local plan = bounds.object(reply.value)
    assert(plan and plan.ready == true, "plan is not ready")
    local digest = bounds.line(plan.digest, 64)
    assert(digest and #digest == 64, "missing plan digest")
    return digest
end
local function applied(request: unknown, digest: string)
    local reply = call("apply", request, digest)
    assert(reply.ok == true, "apply failed: " .. tostring(reply.code) .. " " .. tostring(reply.message))
    local receipt = bounds.object(reply.value)
    assert(receipt and receipt.state == "complete", "operation did not complete: " .. tostring(receipt and receipt.message))
    local replay = call("apply", request, digest)
    assert(replay.ok == true and replay.replayed == true, "operation retry did not reuse its receipt")
end
local function main()
    local baseline = assert(registry.snapshot())
    local scope, scope_error = security.named_scope("bee.hub.security:execution_scope")
    assert(not scope and scope_error, "caller obtained private Hub execution scope")
    local backend, backend_error = funcs.new():call("bee.hub.binding:backend", {operation = "installed"})
    local backend_reply = bounds.object(backend)
    assert(backend_error or (backend_reply and backend_reply.ok == false and backend_reply.code == "DENIED"), "caller reached private backend")
    local changes = assert(baseline:changes())
    local staged = changes:create({id = "bee.hub.deps:forbidden", kind = "ns.dependency", data = {component = "wippy/test", version = "0.4.17"}})
    if staged then assert(not changes:apply(), "caller obtained direct registry publication") end
    local install = {action = "install", component = "wippy/test", version = "0.4.16"}
    local install_digest = prepare(install)
    assert(assert(registry.snapshot()):version():id() == baseline:version():id(), "planning changed registry history")
    local mismatch = call("apply", {action = "install", component = "wippy/test", version = "0.4.17"}, install_digest)
    assert(mismatch.ok == false and mismatch.code == "STALE", "different request reused a confirmation: " .. tostring(mismatch.code) .. " " .. tostring(mismatch.message))
    assert(assert(registry.snapshot()):version():id() == baseline:version():id(), "rejected confirmation changed registry history")
    applied(install, install_digest)
    local completed_revision = assert(registry.snapshot()):version():id()
    for _, changed in ipairs({
        {action = "install", component = "wippy/test", version = "0.4.17"},
        {action = "update", component = "wippy/test", version = "0.4.16"},
        {action = "install", component = "wippy/test", version = "0.4.16", migration_policy = "up"},
        {action = "install", component = "wippy/test", version = "0.4.16", parameters = {{name = "test:target", value = "other:db"}}},
    }) do
        local replay = call("apply", changed, install_digest)
        assert(replay.ok == false and replay.code == "STALE", "changed request reused a completed receipt: " .. tostring(replay.code))
    end
    local explicit_defaults = call("apply", {action = "install", component = "wippy/test", version = "0.4.16", migration_policy = "none", parameters = {}}, install_digest)
    assert(explicit_defaults.ok == true and explicit_defaults.replayed == true, "equivalent defaults failed receipt replay")
    assert(assert(registry.snapshot()):version():id() == completed_revision, "receipt replay changed registry history")
    local installed_state = assert(assert(registry.snapshot()):state())
    for _, entry in ipairs(installed_state.entries) do
        if entry.kind == "ns.dependency" then
            logger:info("HUB_ROOT_OBSERVATION id=" .. entry.id .. " owner=" .. tostring(entry.registry and entry.registry.owner)
                .. " root=" .. tostring(entry.registry and entry.registry.root))
        end
    end
    local update = {action = "update", component = "wippy/test", version = "0.4.17"}
    applied(update, prepare(update))
    local uninstall = {action = "uninstall", component = "wippy/test"}
    applied(uninstall, prepare(uninstall))
    local status = call("status", nil, install_digest)
    assert(status.ok == true, "receipt disappeared after later operations")
    logger:info("HUB_MANAGE_PASS")
end
local function narrow()
    local result, problem = funcs.new():call("bee.hub.binding:call", {operation = "plan",
        request = {action = "install", component = "wippy/test", version = "0.4.16"}})
    assert(not problem, tostring(problem))
    local reply = assert(bounds.object(result))
    assert(reply.ok == false and reply.code == "DENIED", "component-only read exposed plan inventory")
    logger:info("HUB_MANAGE_NARROW_PASS")
end
local function reader()
    local request = {action = "install", component = "wippy/test", version = "0.4.16"}
    local review, review_error = funcs.new():call("bee.hub.binding:call", {operation = "plan", request = request})
    assert(not review_error, tostring(review_error))
    local plan = assert(bounds.object(review))
    local value = assert(bounds.object(plan.value))
    local denied, denied_error = funcs.new():call("bee.hub.binding:call", {operation = "apply", request = request,
        expected_digest = value.digest})
    assert(not denied_error, tostring(denied_error))
    local denied_reply = assert(bounds.object(denied))
    assert(denied_reply.ok == false and denied_reply.code == "DENIED", "read-only caller applied a plan")
    logger:info("HUB_MANAGE_READER_PASS")
end
local function restart()
    local snapshot = assert(registry.snapshot())
    local state = assert(snapshot:state())
    local receipts = 0
    for _, entry in ipairs(state.entries) do
        if entry.id:sub(1, 19) == "bee.hub.operations:" then
            local data = bounds.object(entry.data)
            assert(data and data.state == "complete", "restart lost completed operation state")
            receipts = receipts + 1
        end
        if entry.kind == "ns.dependency" then
            local data = bounds.object(entry.data)
            assert(not data or data.component ~= "wippy/test", "removed package root returned after restart")
        end
    end
    assert(receipts == 3, "restart lost Hub operation history: " .. tostring(receipts))
    logger:info("HUB_MANAGE_RESTART_PASS")
end
local function checked(run: () -> ())
    local ok, problem = pcall(run)
    if not ok then logger:error("HUB_MANAGE_FAILURE " .. tostring(problem)); error(tostring(problem)) end
end
return {main = function() checked(main) end, narrow = function() checked(narrow) end,
    reader = function() checked(reader) end, restart = function() checked(restart) end}
