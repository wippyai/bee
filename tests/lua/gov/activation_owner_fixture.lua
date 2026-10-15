-- MIT. Destination orchestration keeps selection, approval, desired state and
-- overlay observation in their separate owners.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local KERNEL: {revision: integer, namespaces: {string}, super_edit: {string}, entries: {string}} =
    {revision = 1, namespaces = {"bee.gov"}, super_edit = {}, entries = {"bee.gov:protected_kernel"}}
local hash = require("hash")
local canonical = require("canonical")
local artifact = require("artifact")
local plan_store = require("plan_store")
local activation_store = require("activation_store")
local owner = require("activation_owner")
local lease_store = require("lease_store")
local preflight = require("preflight")
local application_admission = require("application_admission")
local capability_grants = require("capability_grants")
local capability_model = require("capability_model")
local migration_work = require("migration_work")

local SHA = string.rep("a", 64)
local SHA_B = string.rep("b", 64)
local EMPTY_STRINGS: {string} = {}
type Object = {[string]: unknown}

type ResolverWorld = {revision: integer, digest: string,
    application_admission: application_admission.Measurement?,
    capability: preflight.CapabilityEvidence?, blocked: boolean?}
type MigrationEffects = owner.MigrationEffects

local function candidate_entry(id: string, kind: string, package: string, digest: string): preflight.Entry
    return {id = id, kind = kind, package = package, digest = digest, references = EMPTY_STRINGS,
        auto_start = false, grants = EMPTY_STRINGS, modules = EMPTY_STRINGS,
        config_objects = EMPTY_STRINGS, config_lists = EMPTY_STRINGS, config_empty = EMPTY_STRINGS}
end

local function blob(bytes: string): {[string]: string}
    local digest, err = hash.sha256(bytes)
    if not digest then error(tostring(err)) end
    return {bytes = bytes, digest = digest}
end

local function expect_code(result: {[string]: unknown}, expected: string)
    local failure = bounds.object(result.error)
    test.is_true(result.code == expected, "expected " .. expected .. ", got "
        .. tostring(result.code or (failure and failure.code)) .. ": "
        .. tostring(result.message or (failure and failure.message)))
end
local function ok(result: {[string]: unknown}): {[string]: unknown}
    if result.ok ~= true then
        local failure = bounds.object(result.error)
        error(tostring(result.code or (failure and failure.code)) .. ": "
            .. tostring(result.message or (failure and failure.message)))
    end
    return assert(bounds.object(result.value))
end
local function migration_effect(): MigrationEffects
    return {
        matches = function(_owner: string, _work: migration_work.Work, _intent: unknown): (boolean?, string?) return false, nil end,
        prepare = function(_owner: string, _work: migration_work.Work, _intent: unknown): ({[string]: unknown}?, string?) return {changed = false}, nil end,
        clear = function(_owner: string): ({[string]: unknown}?, string?) return {changed = false}, nil end,
        cleared = function(_owner: string): (boolean?, string?) return true, nil end,
        execute = function(_work: migration_work.Work, _intent: unknown): ({bytes: string, digest: string}?, boolean, string?)
            return nil, false, "unexpected migration execution"
        end,
    }
end

local function selected_plan(store: plan_store.Store, version: string, entry_blob: {[string]: unknown}, author: string?): {[string]: unknown}
    local identity = {source_node = "source-a", source_workspace = "app-a", version = version}
    local staged = ok(plan_store.call(store, "host-a", {operation = "stage", expected_revision = 0,
        idempotency_key = "stage-" .. version, source_node = identity.source_node,
        source_workspace = identity.source_workspace, version = version,
        candidate = blob("candidate-" .. version), artifact = entry_blob,
        preflight = blob("source-preflight-" .. version), author = author}))
    local reviewed = ok(plan_store.call(store, "host-a", {operation = "record_review",
        expected_revision = staged.revision, idempotency_key = "review-" .. version,
        source_node = identity.source_node, source_workspace = identity.source_workspace,
        version = version, review_status = "accepted", review_reason = "reviewed exact bytes"}))
    return ok(plan_store.call(store, "host-a", {operation = "select",
        expected_revision = reviewed.revision, idempotency_key = "select-" .. version,
        source_node = identity.source_node, source_workspace = identity.source_workspace,
        version = version}))
end

local function admission(artifact_digest: string, policy_digest: string, overlay_owner: string?, workspace_id: string?): application_admission.Measurement
    local measured, measure_error = application_admission.measure({schema_revision = application_admission.SCHEMA,
        workspace_id = workspace_id or "workspace-owner", overlay_owner = overlay_owner or "bee.gov:test-overlay",
        source_node = "source-a", source_workspace = "app-a", artifact_digest = artifact_digest,
        policy_digest = policy_digest, bindings = {}})
    if not measured then error(tostring(measure_error)) end
    return measured
end

local function installed_capability(review: capability_grants.Review?): preflight.CapabilityEvidence
    local vocabulary: capability_model.Vocabulary = {revision = 1, never = {}, capabilities = {}}
    local proposal, proposal_error = capability_grants.propose(vocabulary, "bee.gov:test-overlay",
        "demo:run", {}, nil)
    if not proposal then error(tostring(proposal_error)) end
    local raw, record_error = capability_grants.record("bee.gov:test-overlay", "workspace-owner",
        "demo:run", proposal, "prior-approval", 1, SHA, "v1")
    if not raw then error(tostring(record_error)) end
    local installed, decode_error = capability_grants.decode(raw, "bee.gov:test-overlay",
        "workspace-owner", "demo:run", vocabulary)
    if not installed then error(tostring(decode_error)) end
    local measured_review, review_error = capability_grants.diff(vocabulary, installed, proposal)
    if not measured_review then error(tostring(review_error)) end
    return {kind = "installed", proposal = proposal, installed = installed, review = review or measured_review}
end

local function shifting_resolver(entry: {[string]: unknown}, world: ResolverWorld): owner.Resolver
    local entry_bytes, encode_error = canonical.encode(entry)
    if not entry_bytes then error(tostring(encode_error)) end
    local selected_digest, digest_error = hash.sha256(entry_bytes)
    if not selected_digest then error(tostring(digest_error)) end
    local value = {}
    function value.resolve(self: owner.Resolver, plan: unknown): (preflight.Candidate?, preflight.Context?, string?)
        local selected = assert(bounds.object(plan))
        local version = selected.version
        assert(type(version) == "string")
        local entry_id, entry_kind = entry.id, entry.kind
        local candidate_entries: {preflight.Entry} = {
            candidate_entry(entry_id, entry_kind, "demo/app", selected_digest)}
        local candidate: preflight.Candidate = {destination_node = "node-owner", source_node = "source-a",
            base_revision = world.revision, base_digest = world.digest,
            artifacts = {{component = "demo/app", version = version,
                digest = SHA, dependencies = {}, namespaces = {"demo"}}},
            entries = candidate_entries, requirements = {}, migrations = {}}
        local application_evidence: preflight.AdmissionEvidence = {kind = "absent"}
        if world.application_admission then
            application_evidence = {kind = "measured", value = world.application_admission}
        end
        local host_evidence: preflight.HostEvidence = {
            application_admission = application_evidence,
            capability = world.capability or {kind = "absent"}}
        local packages: {[string]: boolean} = { ["demo/app"] = true }
        if world.blocked == true then packages["demo/app"] = false end
        local context: preflight.Context = {node_id = "node-owner", registry_revision = world.revision,
                registry_digest = world.digest,
                policy_digest = SHA, packages = packages, namespaces = {demo = true},
                kinds = {[entry_kind] = true}, databases = {}, grants = {}, modules = {},
                entries = {}, installed_entries = nil, applied = {}, exact_expansion = true, protected = KERNEL,
                migration_barrier = false, auto_start = true, host_evidence = host_evidence}
        return candidate, context, nil
    end
    return value
end

local function resolver(entry: {[string]: unknown}): owner.Resolver
    return shifting_resolver(entry, {revision = 4, digest = SHA})
end

local function migration_resolver(entry: {[string]: unknown}, state: {[string]: unknown}): owner.Resolver
    local checksum = assert(hash.sha256(assert(canonical.encode(entry))))
    local value = {}
    function value.resolve(self: owner.Resolver, plan: unknown): (preflight.Candidate?, preflight.Context?, string?)
        local selected = assert(bounds.object(plan))
        assert(type(selected.version) == "string")
        local applied: {[string]: preflight.Migration} = {}
        if state.executed == true then
            applied["host:db\ndemo:001"] = {id = "demo:001", target_db = "host:db", checksum = checksum, ordinal = 1}
        end
        local database = candidate_entry("host:db", "db.sql.sqlite", "host/base", SHA)
        local migration_entry = candidate_entry("demo:001", "function.lua", "demo/app", checksum)
        local candidate_entries: {preflight.Entry} = {migration_entry}
        local candidate: preflight.Candidate = {destination_node = "node-owner", source_node = "source-a", base_revision = 4, base_digest = SHA,
            artifacts = {{component = "demo/app", version = selected.version, digest = SHA,
                dependencies = {}, namespaces = {"demo"}}}, entries = candidate_entries, requirements = {},
            migrations = {{id = "demo:001", target_db = "host:db", checksum = checksum, ordinal = 1}}}
        local context: preflight.Context = {node_id = "node-owner", registry_revision = 4, registry_digest = SHA,
            policy_digest = type(state.policy_digest) == "string" and state.policy_digest or SHA,
            packages = {["demo/app"] = true}, namespaces = {demo = true}, kinds = {["function.lua"] = true},
            databases = {["host:db"] = true}, grants = {}, modules = {}, entries = {["host:db"] = database},
            installed_entries = nil,
            database_bindings = nil, applied = applied, applied_databases = nil,
            exact_expansion = true, protected = KERNEL, migration_barrier = true, auto_start = true,
            host_evidence = {application_admission = {kind = "absent"}, capability = {kind = "absent"}}}
        return candidate, context, nil
    end
    return value
end

local function approvals(): owner.Executor
    local value = {}
    function value.call(self: owner.Executor, method: string, request: unknown): (unknown?, unknown?)
        local input = assert(bounds.object(request))
        if method == "bee.approvals.binding:request" then
            local proposal = assert(bounds.object(input.proposal))
            return {ok = true, value = {approval_id = "approval-v1", proposal = proposal,
                proposal_digest = assert(hash.sha256(assert(canonical.encode(proposal)))),
                owner_incarnation = 3}}, nil
        end
        return {ok = true, value = {approval_id = input.approval_id,
            proposal_digest = input.proposal_digest, consumer_id = "destination-host",
            consumed_effect = input.effect_key}}, nil
    end
    return value
end

local function lossy_approvals(): owner.Executor
    local value = {}
    local consumed = false
    function value.call(self: owner.Executor, method: string, request: unknown): (unknown?, unknown?)
        local input = assert(bounds.object(request))
        if method == "bee.approvals.binding:request" then
            local proposal = assert(bounds.object(input.proposal))
            return {ok = true, value = {approval_id = "approval-crash", proposal = proposal,
                proposal_digest = assert(hash.sha256(assert(canonical.encode(proposal)))),
                owner_incarnation = 3}}, nil
        end
        if not consumed then
            consumed = true
            return nil, "approval reply was lost after commit"
        end
        return {ok = true, value = {approval_id = input.approval_id,
            proposal_digest = input.proposal_digest, consumer_id = "destination-host",
            consumed_effect = input.effect_key}}, nil
    end
    return value
end

local function definite_failure_test(broken_source: boolean?)
    local workspace = broken_source and "workspace-legacy-syntax" or "workspace-definite-failure"
    local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
    local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
    local entry = {id = "demo:run", kind = "function.lua", data = {source = broken_source
        and "-- line\n-- line\n-- line\n-- line\nlocal status =    +" or "return true"}}
    local exact = assert(artifact.create({entry}))
    selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
    local attempts = 0
    local config: owner.Config = {plans = plans, activations = activations,
        resolver = shifting_resolver(entry, {revision = 4, digest = SHA}), approvals = approvals(),
        actor_id = "host-a", consumer_id = "destination-host", overlay_owner = "bee.gov:test-overlay",
        approval_policy = "local-install", migrations = migration_effect(),
        matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?) return false, nil end,
        apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
            attempts = attempts + 1
            return nil, "failed to add library node: demo:run:5:19: syntax error", true
        end}
    ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
        version = "v1", intent_id = "intent-definite", receipt_key = "definite"}))
    local failed = ok(owner.advance(config, "intent-definite", "definite"))
    test.eq(failed.phase, "settled")
    test.eq(failed.outcome, "failed")
    test.contains(tostring(failed.diagnostics), "demo:run:5:19")
    test.eq(attempts, broken_source and 0 or 1)
    test.eq(ok(owner.advance(config, "intent-definite", "definite")).outcome, "failed")
    test.eq(attempts, broken_source and 0 or 1)
    assert(activation_store.close(activations))
    assert(plan_store.close(plans))
end

local function queued_failure_test()
    local plans = assert(plan_store.open("bee:db", "node-owner", "workspace-slot-handoff"))
    local activations = assert(activation_store.open("bee:db", "node-owner", "workspace-slot-handoff"))
    local entry = {id = "demo:run", kind = "function.lua", data = {source = "return true"}}
    local exact = assert(artifact.create({entry}))
    local executor = {}
    function executor.call(self: owner.Executor, method: string, request: unknown): (unknown?, unknown?)
        local input = assert(bounds.object(request))
        if method == "bee.approvals.binding:request" then
            local proposal = assert(bounds.object(input.proposal))
            local payload = assert(bounds.object(proposal.payload))
            return {ok = true, value = {approval_id = "queued-approval-" .. tostring(payload.version), proposal = proposal,
                proposal_digest = assert(hash.sha256(assert(canonical.encode(proposal)))), owner_incarnation = 3}}, nil
        end
        return {ok = true, value = {approval_id = input.approval_id, proposal_digest = input.proposal_digest,
            consumer_id = "destination-host", consumed_effect = input.effect_key}}, nil
    end
    local installed = false
    local config: owner.Config = {plans = plans, activations = activations,
        resolver = shifting_resolver(entry, {revision = 4, digest = SHA}), approvals = executor,
        actor_id = "host-a", consumer_id = "destination-host", overlay_owner = "bee.gov:test-overlay",
        approval_policy = "local-install", migrations = migration_effect(),
        matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?) return installed, nil end,
        apply = function(_overlay: string, _entries: unknown, _admission: unknown?, raw: unknown): ({[string]: unknown}?, string?, boolean?)
            if assert(bounds.object(raw)).version == "v1" then return nil, "demo:run:5:19: syntax error", true end
            installed = true
            return {changed = true}, nil, nil
        end}
    selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
    ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a", version = "v1",
        intent_id = "queued-first", receipt_key = "queued-first"}))
    test.eq(ok(owner.step(config, "queued-first", "queued-first")).phase, "consuming")
    test.eq(ok(owner.step(config, "queued-first", "queued-first")).phase, "authorized")
    test.eq(ok(owner.step(config, "queued-first", "queued-first")).phase, "applying")
    selected_plan(plans, "v2", {bytes = exact.bytes, digest = exact.digest})
    ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a", version = "v2",
        intent_id = "queued-second", receipt_key = "queued-second"}))
    test.eq(ok(owner.step(config, "queued-second", "queued-second")).phase, "consuming")
    expect_code(owner.step(config, "queued-second", "queued-second"), "CONFLICT")
    test.eq(ok(owner.advance(config, "queued-first", "queued-first")).outcome, "failed")
    test.eq(ok(owner.advance(config, "queued-second", "queued-second")).outcome, "applied")
    test.eq(installed, true)
    assert(activation_store.close(activations))
    assert(plan_store.close(plans))
end

local LEASE_GRANT: capability_model.Grant = {capability = "workspace.files.write", template_revision = 1,
    operation = "files.write", resource = "workspace", scope = {subpath = "alpha"}, parameters = {subpath = "alpha"}}
local LEASE_NARROW: capability_model.Grant = {capability = "workspace.files.write", template_revision = 1,
    operation = "files.write", resource = "workspace", scope = {subpath = "alpha/child"},
    parameters = {subpath = "alpha/child"}}
local LEASE_OUTSIDE: capability_model.Grant = {capability = "workspace.files.write", template_revision = 1,
    operation = "files.write", resource = "workspace", scope = {subpath = "beta"}, parameters = {subpath = "beta"}}

-- Installed evidence whose measured proposal widens beyond the installed set.
local function widening_capability(proposed: {capability_model.Grant}): preflight.CapabilityEvidence
    local evidence = installed_capability(nil)
    if evidence.kind ~= "installed" then error("installed capability evidence is missing") end
    local proposal = evidence.proposal
    proposal.capabilities = proposed
    local review: capability_grants.Review = {added = {}, widened = {}, narrowed = {}, removed = {}, changed = {},
        requires_approval = true, revocation = {grants = {}, fenced_attempts = {}},
        lines = {"widened: Write alpha"}, resolved = {"Write alpha"}, delta = {"widened: Write alpha"}}
    return {kind = "installed", proposal = proposal, installed = evidence.installed, review = review}
end

local function lease_config(workspace: string, capability: preflight.CapabilityEvidence,
    executor: owner.Executor): (owner.Config, plan_store.Store, activation_store.Store, lease_store.Store, {[string]: boolean})
    local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
    local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
    local leases = assert(lease_store.open("bee:db", "node-owner", workspace))
    local entry = {id = "demo:run", kind = "function.lua", data = {source = "return true"}}
    local exact = assert(artifact.create({entry}))
    selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
    local flags: {[string]: boolean} = {applied = false}
    local config: owner.Config = {plans = plans, activations = activations,
        resolver = shifting_resolver(entry, {revision = 4, digest = SHA, capability = capability}),
        approvals = executor, actor_id = "host-a", consumer_id = "destination-host",
        overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
        leases = leases,
        matches = function(_overlay: string, _entries: unknown, _admission: unknown?,
            _intent: unknown): (boolean?, string?) return flags.applied, nil end,
        apply = function(_overlay: string, _entries: unknown, _admission: unknown?,
            _intent: unknown): ({[string]: unknown}?, string?, boolean?)
            flags.applied = true
            return {changed = true}, nil
        end}
    return config, plans, activations, leases, flags
end

local function grant_lease(leases: lease_store.Store, max_applies: integer): {[string]: unknown}
    return ok(lease_store.call(leases, "host-a", {operation = "grant", idempotency_key = "grant-lease",
        lease_id = "lease-1", target = "bee.gov:test-overlay", envelope = {LEASE_GRANT},
        source_approval_id = "lease-approval", source_approval_proposal_digest = SHA_B,
        source_approval_owner_incarnation = 2, granted_by = "person-a", max_applies = max_applies}))
end


return {SHA = SHA, SHA_B = SHA_B, blob = blob, expect_code = expect_code, ok = ok, migration_effect = migration_effect, selected_plan = selected_plan, admission = admission, installed_capability = installed_capability, shifting_resolver = shifting_resolver, resolver = resolver, migration_resolver = migration_resolver, approvals = approvals, lossy_approvals = lossy_approvals, definite_failure_test = definite_failure_test, queued_failure_test = queued_failure_test, LEASE_NARROW = LEASE_NARROW, LEASE_OUTSIDE = LEASE_OUTSIDE, widening_capability = widening_capability, lease_config = lease_config, grant_lease = grant_lease}
