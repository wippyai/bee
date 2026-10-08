-- MIT
local process = require("process")
local env = require("env")
local registry = require("registry")
local system = require("system")
local funcs = require("funcs")
local fs = require("fs")
local json = require("json")
local time = require("time")
local protocol = require("protocol")
local example = require("example")
local model = require("model")
local grants = require("grants")
local materializer = require("materializer")
local application = require("application")
local bounds = require("bounds")
type Object = {[string]: unknown}
local WORKSPACE = "012345678901234567890123456789ab"
local OWNER = "bee.e2e.sdk:installed"
local function install(node: string, peer: string)
    local entries = example.entries(peer, WORKSPACE, peer)
    local vocabulary = assert(model.decode(assert(registry.get("bee.capability:catalog"))))
    local requirements: {Object} = {}
    for _, entry in ipairs(entries) do
        if entry.kind == "ns.requirement" then
            local meta = assert(bounds.object(entry.meta))
            local data = assert(bounds.object(entry.data))
            local target = (data.targets :: {Object})[1]
            requirements[#requirements + 1] = {id = entry.id, expected_kind = "security.policy", targets = {target.entry},
                capability_request = {capability = meta.capability, parameters = meta.parameters,
                    catalog_revision = model.revisions(vocabulary, tostring(meta.capability)),
                    template_revision = vocabulary.capabilities[tostring(meta.capability)].revision,
                    target = target.entry, path = target.path}}
        end
    end
    local proposal = assert(grants.propose(vocabulary, OWNER, example.APP, requirements))
    local record = assert(grants.record(OWNER, WORKSPACE, example.APP, proposal, "e2e-local-consent-" .. node, 1))
    assert(materializer.reconcile_composed(OWNER, entries, nil,
        {policies = proposal.policies, bindings = proposal.bindings, record = record}))
    local policies: {string} = {}
    for _, policy in ipairs(proposal.policies) do policies[#policies + 1] = tostring(policy.id) end
    local changes = assert(registry.snapshot()):changes()
    changes:create({id = "bee.e2e.sdk:admission", kind = "registry.entry", meta = {type = "bee.node.application_admission"},
        data = {bindings = {{definition_id = example.APP, policies = policies}}}})
    assert(changes:apply())
end
local function proof(): Object
    local node = assert(system.node.id())
    local folder = assert(system.process.cwd())
    local label = folder:match("([^/]+)$")
    if label ~= "alpha" and label ~= "beta" then error("SDK fixture requires alpha or beta") end
    assert(process.registry.register("bee.e2e.sdk/" .. label, process.pid(), process.registry.EVENTUAL))
    local peer_label = label == "alpha" and "beta" or "alpha"
    local peer_pid: string? = nil
    for _ = 1, 300 do
        local found = process.registry.lookup("bee.e2e.sdk/" .. peer_label, process.registry.EVENTUAL)
        if found then peer_pid = tostring(found); break end
        time.after("100ms"):receive()
    end
    if not peer_pid then error("peer fixture is absent") end
    local peer = protocol.node_of(peer_pid, node)
    assert(peer ~= node, "peer fixture must run on a second node")
    install(node, peer)
    assert(process.registry.register("bee.e2e.sdk/ready/" .. label, process.pid(), process.registry.EVENTUAL))
    if label == "beta" then return {ok = true, role = label, node = node} end
    local ready = false
    for _ = 1, 300 do
        if process.registry.lookup("bee.e2e.sdk/ready/beta", process.registry.EVENTUAL) then ready = true; break end
        time.after("100ms"):receive()
    end
    assert(ready, "beta application is not ready")
    local definition = assert(application.definition(example.APP))
    local actor = assert(application.actor(WORKSPACE, "two-node-sdk", definition, 1))
    local scope = assert(application.scope(definition, WORKSPACE))
    local answer, err = funcs.new():with_actor(actor):with_scope(scope):call(example.PEER,
        {node = peer, configuration = "ci", inputs = {1, 2, 3}})
    assert(not err, tostring(err))
    local reply = assert(bounds.object(answer))
    assert(reply.ok == true, assert(json.encode(reply)))
    local value = assert(bounds.object(reply.value))
    local remote = assert(bounds.object(value.remote))
    local result = assert(bounds.object(remote.value))
    assert(remote.ok == true and result.configuration == "ci" and result.total == 18, assert(json.encode(remote)))
    assert(protocol.node_of(tostring(value.source_pid), node) == node, "source application runs on alpha")
    assert(protocol.node_of(tostring(result.worker_pid), node) == peer, "worker application runs on beta")
    return {ok = true, source_node = node, destination_node = peer, source_pid = value.source_pid,
        worker_pid = result.worker_pid, configuration = result.configuration, total = result.total}
end
local function main()
    local events = assert(process.events())
    if env.get("bee:role") == "client" then events:receive(); return end
    local succeeded, result = pcall(proof)
    local volume = assert(fs.get("bee.env:workspace_root"))
    assert(volume:writefile("hive-sdk-proof.json", assert(json.encode(succeeded and result or {ok = false, error = tostring(result)}))))
    events:receive()
end
return {main = main}
