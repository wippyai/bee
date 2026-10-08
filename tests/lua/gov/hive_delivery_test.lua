-- MIT. A version one bee published reaches another bee's Library as shared, and
-- installing it there raises that bee's own approval and nothing on the source.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local uuid = require("uuid")
local hash = require("hash")
local canonical = require("canonical")
local artifact = require("artifact")
local delivery = require("delivery")
local publisher = require("publisher")
local destination = require("destination")
local owner = require("activation_owner")
local plan_store = require("plan_store")
local activation_store = require("activation_store")
local replicas = require("replicas")
local replica_fixture = require("replica_fixture")
local sources: {string} = {}
local sync = require("sync")
local preflight = require("preflight")
local governed = require("governed")
local library = require("library")

local KERNEL: {revision: integer, namespaces: {string}, super_edit: {string}, entries: {string}} =
    {revision = 1, namespaces = {"bee.gov"}, super_edit = {}, entries = {"bee.gov:protected_kernel"}}
local SHA = string.rep("a", 64)
local EMPTY_STRINGS: {string} = {}

local function ok(result: {[string]: unknown}): {[string]: unknown}
    if result.ok ~= true then
        local failure = bounds.object(result.error)
        error(tostring(result.code or (failure and failure.code)) .. ": "
            .. tostring(result.message or (failure and failure.message)))
    end
    return assert(bounds.object(result.value))
end

local function reply(value: unknown): governed.Reply
    local result = governed.reply({ok = true, value = value, replayed = false})
    if not result then error("valid fixture reply was rejected") end
    return result
end

-- The destination's resolution of the delivered artifact: one application
-- entry the host's policy admits.
local function resolver(node: string, entry: {[string]: unknown}, component: string): owner.Resolver
    local entry_bytes = assert(canonical.encode(entry))
    local entry_digest = assert(hash.sha256(entry_bytes))
    local value = {}
    function value.resolve(self: owner.Resolver, plan: unknown): (preflight.Candidate?, preflight.Context?, string?)
        local selected = assert(bounds.object(plan))
        local version = selected.version
        assert(type(version) == "string" and type(selected.source_node) == "string")
        local entry_kind = entry.kind
        local candidate: preflight.Candidate = {destination_node = node, source_node = selected.source_node,
            base_revision = 4, base_digest = SHA,
            artifacts = {{component = component, version = version, digest = SHA, dependencies = {}, namespaces = {"app.notes"}}},
            entries = {{id = entry.id, kind = entry_kind, package = component, digest = entry_digest,
                references = EMPTY_STRINGS, auto_start = false, grants = EMPTY_STRINGS, modules = EMPTY_STRINGS,
                config_objects = EMPTY_STRINGS, config_lists = EMPTY_STRINGS, config_empty = EMPTY_STRINGS}},
            requirements = {}, migrations = {}}
        local context: preflight.Context = {node_id = node, registry_revision = 4, registry_digest = SHA,
            policy_digest = SHA, packages = {[component] = true}, namespaces = {["app.notes"] = true},
            kinds = {[entry_kind] = true}, databases = {}, grants = {}, modules = {},
            entries = {}, installed_entries = nil, applied = {}, exact_expansion = true, protected = KERNEL,
            migration_barrier = false, auto_start = true,
            host_evidence = {application_admission = {kind = "absent"}, capability = {kind = "absent"}}}
        return candidate, context, nil
    end
    return value
end

local function define_tests()
    test.describe("hive delivery of an application version", function()
        test.it("publishes on one bee, appears as shared on another, and installs through that bee's approval", function()
            local suffix = assert(uuid.v7())
            local source_node = "node-a-" .. suffix
            sources[#sources + 1] = source_node
            local node = "node-b-" .. suffix
            local workspace = "workspace-b-" .. suffix
            local entry = {id = "app.notes:main", kind = "function.lua", data = {source = "return 'notes'"}}
            local exact = assert(artifact.create({entry}))

            -- Bee A publishes the version it made; the Sync feed carries its descriptor.
            local published = ok(publisher.publish(source_node, {source_workspace = "notes", component = "app.notes",
                version = "1.0.0", author = "Claude Code", artifact = {bytes = exact.bytes, digest = exact.digest}}))
            local descriptor = assert(bounds.object(published.descriptor))
            local feed = assert(sync.open({owner = source_node}))
            local page = ok(sync.read_after(feed, delivery.FEED, 0, 16))
            test.eq(#(principals.objects(page.events)), 1)
            assert(sync.close(feed))

            -- Bee B holds the replicated version; its Library lists it as shared from bee A.
            local replica_store = assert(replicas.open())
            local replicated = ok(replicas.available(replica_store, source_node, delivery.FEED, 16))
            local versions = principals.objects(replicated.items)
            test.eq(#versions, 1)
            local state = library.new(workspace)
            test.is_true(governed.apply_list(state.governed, reply({owner_node = node, workspace_id = workspace, plans = {}})))
            test.is_true(governed.apply_available(state.governed, reply({workspace_id = workspace, versions = versions})))
            local shared = library.rows(state, "shared")
            test.eq(#shared, 1)
            test.eq(shared[1].name, "Notes")
            test.eq(shared[1].version, "1.0.0")
            test.eq(shared[1].status, "Shared")
            test.eq(shared[1].source, "from bee " .. source_node:sub(1, 16))
            test.eq(#library.rows(state, "installed"), 0)
            local made_by = ""
            for _, line in ipairs(library.version_lines(state, shared[1])) do
                if line.label == "Made by" then made_by = line.value end
            end
            test.eq(made_by, "Claude Code")
            test.is_true(governed.apply_names(state.governed, reply({names = {[source_node] = "laptop"}})))
            test.eq(library.rows(state, "shared")[1].source, "from bee laptop")

            -- Install on bee B: receive, review, choose and ask for approval in B's own stores.
            local plans = assert(plan_store.open("bee:db", node, workspace))
            local activations = assert(activation_store.open("bee:db", node, workspace))
            local resolved = resolver(node, entry, "app.notes")
            local staged = ok(destination.stage_replica(plans, replica_store, "local-reviewer",
                {source_owner = source_node, feed = delivery.FEED, version_key = descriptor.key,
                    descriptor_digest = descriptor.digest, idempotency_key = "stage-" .. suffix},
                resolved, "app.notes"))
            test.eq(staged.status, "staged")
            test.eq(staged.source_node, source_node)
            local identity = {source_node = source_node, source_workspace = "notes", version = "1.0.0"}
            local reviewed = ok(plan_store.call(plans, "local-reviewer", {operation = "record_review",
                expected_revision = staged.revision, idempotency_key = "review-" .. suffix,
                source_node = identity.source_node, source_workspace = identity.source_workspace,
                version = identity.version, review_status = "accepted", review_reason = "reviewed in the Library"}))
            ok(plan_store.call(plans, "local-reviewer", {operation = "select", expected_revision = reviewed.revision,
                idempotency_key = "select-" .. suffix, source_node = identity.source_node,
                source_workspace = identity.source_workspace, version = identity.version}))

            local requested: {[string]: unknown}? = nil
            local approvals = {}
            function approvals.call(self: owner.Executor, method: string, request: unknown): (unknown?, unknown?)
                local input = assert(bounds.object(request))
                test.eq(method, "bee.approvals.binding:request")
                requested = input
                local proposal = assert(bounds.object(input.proposal))
                return {ok = true, value = {approval_id = "approval-" .. suffix, proposal = proposal,
                    proposal_digest = assert(hash.sha256(assert(canonical.encode(proposal)))),
                    owner_incarnation = 3}}, nil
            end
            local applied = false
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolved,
                approvals = approvals, actor_id = "local-reviewer", consumer_id = "destination-host",
                overlay_owner = "bee.gov.apps:" .. workspace .. ".notes", approval_policy = "local-install",
                migrations = {
                    matches = function(_owner: string, _work: unknown): (boolean?, string?) return false, nil end,
                    prepare = function(_owner: string, _work: unknown): ({[string]: unknown}?, string?) return {changed = false}, nil end,
                    clear = function(_owner: string): ({[string]: unknown}?, string?) return {changed = false}, nil end,
                    cleared = function(_owner: string): (boolean?, string?) return true, nil end,
                    execute = function(_work: unknown): ({bytes: string, digest: string}?, boolean, string?)
                        return nil, false, "unexpected migration execution"
                    end},
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?,
                    _intent: unknown): (boolean?, string?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?,
                    _intent: unknown): ({[string]: unknown}?, string?)
                    applied = true
                    return {changed = true}, nil
                end}
            local prepared = ok(owner.prepare(config, {source_node = source_node, source_workspace = "notes",
                version = "1.0.0", intent_id = "intent-" .. suffix, receipt_key = "prepare-" .. suffix}))
            test.eq(prepared.phase, "approval_bound")
            test.eq(prepared.approval_id, "approval-" .. suffix)
            test.not_nil(requested)
            test.is_false(applied)

            -- The Library on bee B reads the activation and says it waits for B's person.
            local listing = ok(activation_store.listing(activations))
            test.is_true(governed.apply_activations(state.governed, reply({workspace_id = workspace,
                activations = principals.objects(listing.activations)})))
            local waiting = library.rows(state, "installed")
            test.eq(#waiting, 1)
            test.eq(waiting[1].status, "Waiting for your approval")
            test.eq(waiting[1].source, "from bee laptop")
            test.eq(#library.rows(state, "shared"), 0)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
            assert(replicas.close(replica_store))
        end)
    end)
end

return function(options)
    return replica_fixture.run(test.run_cases(define_tests), sources, options)
end
