-- MIT. Private-overlay resolution uses immutable definitions with host-owned
-- package, overlay and policy choices. These doubles expose no registry writer.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local artifact = require("artifact")
local resolver = require("overlay_resolver")
local capability_grants = require("capability_grants")
local application_admission = require("application_admission")
local preflight = require("preflight")
local activation_measure = require("activation_measure")
local canonical = require("canonical")
local hash = require("hash")

type Object = {[string]: unknown}
type Entry = {[string]: unknown}
type Policy = resolver.Policy
type Captured = resolver.Captured
type Deps = resolver.Deps
type Facts = {candidate: preflight.Candidate, context: preflight.Context}

local SHA = string.rep("a", 64)

local function proposal(context: preflight.Context): capability_grants.Proposal
    local evidence = context.host_evidence.capability
    if evidence.kind == "absent" then error("capability proposal is missing") end
    return evidence.proposal
end

local function admission(context: preflight.Context): application_admission.Measurement
    local evidence = context.host_evidence.application_admission
    if evidence.kind ~= "measured" then error("application admission was not measured") end
    return evidence.value
end

local function entry(id: string, kind: string, value: string): Entry
    return {id = id, kind = kind, data = {source = "return '" .. value .. "'", value = value}}
end

local function fixture(policy_raw: Policy?): (Deps, Object, {captured: Captured, artifact: artifact.Artifact})
    local made = assert(artifact.create({entry("private.app:main", "function.lua", "main")}))
    local captured: Captured = {
        revision = 19,
        entries = {
            {id = "bee.host:db", kind = "db.sql.sqlite", data = {}, registry = {owner = "bee/host"}},
            {id = "private.app:old-overlay", kind = "function.lua", data = {source = "return 'old-overlay'"}},
            {id = "bee.gov:protected_kernel", kind = "registry.entry", meta = {type = "bee.protected_kernel"},
                data = {revision = 1, namespaces = {"bee.gov"}, super_edit = {}, entries = {"bee.gov:protected_kernel"}},
                registry = {owner = "bee/host"}},
        },
        overlay_ids = { ["private.app:old-overlay"] = true },
        owner = function(item: Entry): (string?, string?)
            local metadata = bounds.object(item.registry)
            if metadata and type(metadata.owner) == "string" then
                return metadata.owner, nil
            end
            return nil, "local registry owner is missing"
        end,
    }
    local policy: Policy
    if policy_raw then
        policy = policy_raw
    else
        policy = {node_id = "node-destination", policy_digest = SHA,
            packages = { ["host/private-app"] = true }, namespaces = { ["private.app"] = true },
            kinds = { ["function.lua"] = true }, databases = { ["bee.host:db"] = true },
            grants = {}, modules = {}, applied = {}, migration_barrier = false}
    end
    local deps: Deps = {
        capture = function(): (resolver.Captured?, string?) return captured, nil end,
        root = function(raw: unknown): (resolver.Root?, string?)
            local spec = assert(bounds.object(raw))
            if spec.source_node ~= "node-source" or spec.source_workspace ~= "author/app" then
                return nil, "private artifact does not match host source mapping"
            end
            assert(type(spec.version) == "string")
            return {component = "host/private-app", version = spec.version}, nil
        end,
        policy = function(_: unknown, _: resolver.Captured, _: resolver.Root): (Policy?, string?) return policy, nil end,
    }
    local spec: Object = {owner_node = "node-destination", workspace_id = "workspace-destination",
        source_node = "node-source", source_workspace = "author/app", version = "v1",
        artifact_bytes = made.bytes, artifact_digest = made.digest}
    return deps, spec, {captured = captured, artifact = made}
end

local function resolve(deps: Deps, spec: Object): Facts
    local candidate, context, err = resolver.resolve_with(deps, spec)
    if not candidate then error(tostring(err)) end
    if not context then error(tostring(err)) end
    return {candidate = candidate, context = context}
end

local function changes(spec: Object, entries: {Entry})
    local made = assert(artifact.create(entries))
    spec.artifact_bytes, spec.artifact_digest = made.bytes, made.digest
end

local function driver_fixture(target_path: string?, action: string?, base: string?): (Deps, Object)
    local name = base or "bee.driver.stub"
    local binding_id = name .. ".binding:binding"
    local items: {Entry} = {
        {id = binding_id, kind = "contract.binding", meta = {type = "harness.driver"}, data = {}},
        {id = name .. ".binding:activation", kind = "ns.requirement", meta = {value_kind = "contract.binding"},
            data = {default = binding_id, targets = {{entry = "bee.harness.launch:harness_activation", path = target_path or ".bindings +="}}}},
        {id = name .. ".security:descriptor_read", kind = "security.policy", data = {policy = {effect = "allow", actions = {action or "registry.get"}, resources = {"*"}}}},
    }
    local made = assert(artifact.create(items))
    local deps, spec, facts = fixture()
    facts.captured.entries[#facts.captured.entries + 1] = {id = "bee.harness.launch:harness_activation", kind = "registry.entry",
        data = {bindings = {"bee.driver.claude.binding:binding"}}, registry = {owner = "bee/host"}}
    for _, entry in ipairs(facts.captured.entries) do
        if entry.id == "bee.gov:protected_kernel" then
            entry.data = {revision = 1, namespaces = {"bee.gov"}, super_edit = {},
                entries = {"bee.gov:protected_kernel", "bee.harness.launch:harness_activation"}}
        end
    end
    deps.root = function(_: unknown): (resolver.Root?, string?) return {component = name, version = "v1"}, nil end
    deps.policy = function(_: unknown, _: resolver.Captured, _: resolver.Root): (Policy?, string?)
        return {node_id = "node-destination", policy_digest = SHA, packages = {[name] = true},
            namespaces = {[name .. ".binding"] = true, [name .. ".security"] = true},
            kinds = {["contract.binding"] = true, ["ns.requirement"] = true, ["security.policy"] = true},
            databases = {}, grants = {[name .. ".security:descriptor_read"] = true}, modules = {}, applied = {}, migration_barrier = false}, nil
    end
    spec.artifact_bytes, spec.artifact_digest = made.bytes, made.digest
    return deps, spec
end


return {SHA = SHA, proposal = proposal, admission = admission, entry = entry, fixture = fixture, resolve = resolve, changes = changes, driver_fixture = driver_fixture}
