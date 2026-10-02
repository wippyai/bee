-- MIT. Destination orchestration keeps selection, approval, desired state and
-- overlay observation in their separate owners.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local KERNEL: {revision: integer, namespaces: {string}, super_edit: {string}, entries: {string}} =
    {revision = 1, namespaces = {"bee.gov"}, super_edit = {}, entries = {"bee.security.gov:protected_kernel"}}
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
type MigrationEffects = {
    matches: (string, migration_work.Work) -> (boolean?, string?),
    prepare: (string, migration_work.Work) -> ({[string]: unknown}?, string?),
    clear: (string) -> ({[string]: unknown}?, string?),
    cleared: (string) -> (boolean?, string?),
    execute: (migration_work.Work) -> ({bytes: string, digest: string}?, boolean, string?)}

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
        matches = function(_owner: string, _work: migration_work.Work): (boolean?, string?) return false, nil end,
        prepare = function(_owner: string, _work: migration_work.Work): ({[string]: unknown}?, string?) return {changed = false}, nil end,
        clear = function(_owner: string): ({[string]: unknown}?, string?) return {changed = false}, nil end,
        cleared = function(_owner: string): (boolean?, string?) return true, nil end,
        execute = function(_work: migration_work.Work): ({bytes: string, digest: string}?, boolean, string?)
            return nil, false, "unexpected migration execution"
        end,
    }
end

local function selected_plan(store: plan_store.Store, version: string, entry_blob: {[string]: unknown}): {[string]: unknown}
    local identity = {source_node = "source-a", source_workspace = "app-a", version = version}
    local staged = ok(plan_store.call(store, "host-a", {operation = "stage", expected_revision = 0,
        idempotency_key = "stage-" .. version, source_node = identity.source_node,
        source_workspace = identity.source_workspace, version = version,
        candidate = blob("candidate-" .. version), artifact = entry_blob,
        preflight = blob("source-preflight-" .. version)}))
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

local function shifting_resolver(entry: {[string]: unknown}, world: ResolverWorld,
    read_revision: boolean?): owner.Resolver
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
    if read_revision then
        function value.revision(self: owner.Resolver): (integer?, string?) return world.revision, nil end
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
    local plans = assert(plan_store.open("bee.gov:plan_test_db", "node-owner", workspace))
    local activations = assert(activation_store.open("bee.gov:activation_test_db", "node-owner", workspace))
    local leases = assert(lease_store.open("bee.gov:activation_test_db", "node-owner", workspace))
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
            _intent: unknown): ({[string]: unknown}?, string?)
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

local function define_tests()
    test.describe("Governance activation owner", function()
        test.it("reuses a contained live grant without requesting a permission decision", function()
            local workspace = "workspace-contained-grant"
            local plans = assert(plan_store.open("bee.gov:plan_test_db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee.gov:activation_test_db", "node-owner", workspace))
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return true"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local evidence = installed_capability(nil)
            if evidence.kind ~= "installed" then error("installed capability evidence is missing") end
            local world: ResolverWorld = {revision = 4, digest = SHA,
                capability = evidence}
            local requests = 0
            local executor = {}
            function executor.call(self: owner.Executor, _method: string, _request: unknown): (unknown?, unknown?)
                requests = requests + 1
                return nil, "reuse must not call Approvals"
            end
            local applied = false
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world), approvals = executor,
                actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install",
                migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?,
                    _intent: unknown): (boolean?, string?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?,
                    _intent: unknown): ({[string]: unknown}?, string?)
                    applied = true
                    return {changed = true}, nil
                end}
            local prepared = ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-contained", receipt_key = "contained"}))
            test.eq(prepared.phase, "authorized")
            test.eq(prepared.approval_id, "prior-approval")
            test.eq(prepared.grant_predecessor_digest, evidence.installed.record_digest)
            test.eq(prepared.grant_reuse_digest, evidence.installed.record_digest)
            test.eq(requests, 0)
            test.eq(ok(owner.step(config, "intent-contained", "contained")).phase, "applying")
            test.eq(ok(owner.step(config, "intent-contained", "contained")).outcome, "applied")
            test.eq(requests, 0)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("shows a widening delta and leaves a refused decision unapplied", function()
            local workspace = "workspace-widened-grant"
            local plans = assert(plan_store.open("bee.gov:plan_test_db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee.gov:activation_test_db", "node-owner", workspace))
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return true"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local review: capability_grants.Review = {added = {}, widened = {}, narrowed = {}, removed = {}, changed = {},
                requires_approval = true, revocation = {grants = {}, fenced_attempts = {}},
                lines = {"widened: Read owned threads"}, resolved = {"Read owned threads"},
                delta = {"widened: Read owned threads"}}
            local world: ResolverWorld = {revision = 4, digest = SHA, capability = installed_capability(review)}
            local seen: {[string]: unknown}? = nil
            local executor = {}
            function executor.call(self: owner.Executor, method: string, request: unknown): (unknown?, unknown?)
                local input = assert(bounds.object(request))
                if method == "bee.approvals.binding:request" then
                    seen = assert(bounds.object(input.proposal))
                    return {ok = true, value = {approval_id = "new-approval", proposal = seen,
                        proposal_digest = assert(hash.sha256(assert(canonical.encode(seen)))),
                        owner_incarnation = 3}}, nil
                end
                return {ok = false, error = {code = "DENIED", message = "person refused widening"}}, nil
            end
            local applied = false
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world), approvals = executor,
                actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install",
                migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?,
                    _intent: unknown): (boolean?, string?) return false, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?,
                    _intent: unknown): ({[string]: unknown}?, string?)
                    applied = true
                    return {changed = true}, nil
                end}
            local prepared = ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-widened", receipt_key = "widened"}))
            test.eq(prepared.phase, "approval_bound")
            local payload = assert(bounds.object((assert(bounds.object(seen))).payload))
            test.eq((principals.strings(payload.permission_changes))[1], "widened: Read owned threads")
            test.eq((principals.strings(payload.resolved_capabilities))[1], "Read owned threads")
            test.eq(ok(owner.step(config, "intent-widened", "widened")).phase, "consuming")
            test.eq(owner.step(config, "intent-widened", "widened").code, "DENIED")
            test.is_false(applied)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("applies a widening covered by an active lease without asking Approvals", function()
            local requests = 0
            local executor = {}
            function executor.call(self: owner.Executor, _method: string, _request: unknown): (unknown?, unknown?)
                requests = requests + 1
                return nil, "a lease-covered change must not call Approvals"
            end
            local config, plans, activations, leases, flags = lease_config("workspace-lease-covered",
                widening_capability({LEASE_NARROW}), executor)
            grant_lease(leases, 1)
            local prepared = ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-lease", receipt_key = "lease"}))
            test.eq(prepared.phase, "authorized")
            test.eq(prepared.approval_id, "lease-approval")
            test.eq(prepared.consumed_consumer_id, "bee.gov.lease_apply")
            test.eq(requests, 0)
            test.eq(ok(owner.step(config, "intent-lease", "lease")).phase, "applying")
            test.eq(ok(owner.step(config, "intent-lease", "lease")).outcome, "applied")
            test.is_true(flags.applied)
            test.eq(ok(lease_store.get(leases, "lease-1")).applies_used, 1)
            test.is_true(lease_store.authorized(leases, "intent-lease") ~= nil)
            assert(lease_store.close(leases))
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("fences a reserved lease use when the lease is revoked before the effect is admitted", function()
            local config, plans, activations, leases, flags = lease_config("workspace-lease-fenced",
                widening_capability({LEASE_NARROW}), approvals())
            grant_lease(leases, 3)
            test.eq(ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-fenced", receipt_key = "fenced"})).phase, "authorized")
            local reserved = ok(lease_store.get(leases, "lease-1"))
            local revoked = ok(lease_store.call(leases, "host-a", {operation = "revoke", idempotency_key = "revoke-fenced",
                lease_id = "lease-1", expected_revision = reserved.revision, revoked_by = "person-a"}))
            test.eq((principals.strings(revoked.fenced_intents))[1], "intent-fenced")
            test.eq(#(principals.strings(revoked.started_effects)), 0)
            test.eq(owner.step(config, "intent-fenced", "fenced").code, "DENIED")
            test.is_false(flags.applied)
            assert(lease_store.close(leases))
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("reports an effect admitted before revocation as started and lets recovery finish it", function()
            local config, plans, activations, leases, flags = lease_config("workspace-lease-started",
                widening_capability({LEASE_NARROW}), approvals())
            grant_lease(leases, 3)
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-started", receipt_key = "started"}))
            test.eq(ok(owner.step(config, "intent-started", "started")).phase, "applying")
            local lease = ok(lease_store.get(leases, "lease-1"))
            local revoked = ok(lease_store.call(leases, "host-a", {operation = "revoke", idempotency_key = "revoke-started",
                lease_id = "lease-1", expected_revision = lease.revision, revoked_by = "person-a"}))
            test.eq((principals.strings(revoked.started_effects))[1], "intent-started")
            test.eq(#(principals.strings(revoked.fenced_intents)), 0)
            test.eq(ok(owner.step(config, "intent-started", "started")).outcome, "applied")
            test.is_true(flags.applied)
            assert(lease_store.close(leases))
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("authorizes an intent and records its lease proof in one commit, once per intent", function()
            local config, plans, activations, leases = lease_config("workspace-lease-atomic",
                widening_capability({LEASE_NARROW}), approvals())
            grant_lease(leases, 1)
            local prepared = ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-atomic", receipt_key = "atomic"}))
            local proof = assert(lease_store.authorized(leases, "intent-atomic"))
            test.eq(proof.approval_id, prepared.approval_id)
            test.eq(proof.approval_proposal_digest, prepared.approval_proposal_digest)
            local lease = ok(lease_store.get(leases, "lease-1"))
            test.eq(lease.applies_used, 1)
            -- The one authorization of this intent cannot be charged again.
            local again = lease_store.call(leases, "host-a", {operation = "use", idempotency_key = "again",
                lease_id = "lease-1", expected_revision = lease.revision, intent_id = "intent-atomic",
                proposal_capabilities = {LEASE_NARROW}})
            test.is_false(again.ok == true)
            -- A retried prepare replays the authorized intent and charges nothing.
            local replayed = ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-atomic", receipt_key = "atomic"}))
            test.eq(replayed.phase, "authorized")
            test.eq(ok(lease_store.get(leases, "lease-1")).applies_used, 1)
            assert(lease_store.close(leases))
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("refuses to apply when the lease proof does not match the intent's authorization", function()
            local config, plans, activations, leases, flags = lease_config("workspace-lease-mismatch",
                widening_capability({LEASE_NARROW}), approvals())
            grant_lease(leases, 3)
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-mismatch", receipt_key = "mismatch"}))
            assert(leases.db:execute("UPDATE bee_governance_lease_uses SET approval_id = 'another-approval'"))
            test.eq(owner.step(config, "intent-mismatch", "mismatch").code, "CONFLICT")
            test.is_false(flags.applied)
            assert(lease_store.close(leases))
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("asks a person when the proposal is outside the lease envelope", function()
            local config, plans, activations, leases = lease_config("workspace-lease-outside",
                widening_capability({LEASE_NARROW, LEASE_OUTSIDE}), approvals())
            grant_lease(leases, 1)
            local prepared = ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-outside", receipt_key = "outside"}))
            test.eq(prepared.phase, "approval_bound")
            test.eq(prepared.approval_id, "approval-v1")
            test.eq(ok(lease_store.get(leases, "lease-1")).applies_used, 0)
            assert(lease_store.close(leases))
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("asks a person after the lease is revoked or exhausted", function()
            local config, plans, activations, leases = lease_config("workspace-lease-revoked",
                widening_capability({LEASE_NARROW}), approvals())
            local granted = grant_lease(leases, 1)
            ok(lease_store.call(leases, "host-a", {operation = "revoke", idempotency_key = "revoke-lease",
                lease_id = "lease-1", expected_revision = granted.revision, revoked_by = "person-a"}))
            local prepared = ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-revoked", receipt_key = "revoked"}))
            test.eq(prepared.phase, "approval_bound")
            test.eq(prepared.approval_id, "approval-v1")
            assert(lease_store.close(leases))
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("establishes only the approved desired version and ignores a newer selection", function()
            local plans, plan_error = plan_store.open("bee.gov:plan_test_db", "node-owner", "workspace-owner")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee.gov:activation_test_db", "node-owner", "workspace-owner")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local applied = false
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolver(entry),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?)
                    applied = true
                    return {changed = true}, nil
                end}
            local prepared = owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-v1", receipt_key = "activation-v1"})
            test.eq(ok(prepared).phase, "approval_bound")
            test.eq(ok(owner.step(config, "intent-v1", "activation-v1")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-v1", "activation-v1")).phase, "authorized")
            test.eq(ok(owner.desired(config)).intent_id, "intent-v1")
            local v2 = assert(artifact.create({{id = "demo:run", kind = "function.lua", data = {source = "return 'v2'"}}}))
            selected_plan(plans, "v2", {bytes = v2.bytes, digest = v2.digest})
            local desired = ok(owner.desired(config))
            test.eq(desired.intent_id, "intent-v1")
            test.eq(desired.version, "v1")
            test.eq(ok(owner.recover(config, "activation-v1")).phase, "applying")
            local settled = ok(owner.recover(config, "activation-v1"))
            test.eq(settled.outcome, "applied")
            test.eq(settled.version, "v1")
            test.is_true(applied)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("yields after exact materialization and remeasures before settling next step", function()
            local workspace = "workspace-activation-yield"
            local plans = assert(plan_store.open("bee.gov:plan_test_db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee.gov:activation_test_db", "node-owner", workspace))
            local entry = {id = "demo:yield", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local world: ResolverWorld = {revision = 4, digest = SHA}
            local applied, apply_count = false, 0
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world, true), approvals = approvals(), actor_id = "host-a",
                consumer_id = "destination-host", overlay_owner = "bee.gov:test-overlay",
                approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?)
                    return applied, nil
                end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?)
                    applied, apply_count = true, apply_count + 1
                    return {changed = true}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-yield", receipt_key = "activation-yield"}))
            test.eq(ok(owner.step(config, "intent-yield", "activation-yield")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-yield", "activation-yield")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-yield", "activation-yield")).phase, "applying")
            local materialized = ok(owner.step(config, "intent-yield", "activation-yield"))
            test.eq(materialized.phase, "applying")
            test.is_true(applied)
            test.eq(apply_count, 1)
            local settled = ok(owner.step(config, "intent-yield", "activation-yield"))
            test.eq(settled.outcome, "applied")
            test.eq(apply_count, 1)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("refuses application admission drift after approval binding", function()
            local workspace = "workspace-admission-drift"
            local plans = assert(plan_store.open("bee.gov:plan_test_db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee.gov:activation_test_db", "node-owner", workspace))
            local entry = {id = "demo:admission-drift", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local world: ResolverWorld = {revision = 4, digest = SHA,
                application_admission = admission(exact.digest, SHA, nil, workspace)}
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world), approvals = approvals(), actor_id = "host-a",
                consumer_id = "destination-host", overlay_owner = "bee.gov:test-overlay",
                approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?) return false, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?) return {changed = true}, nil end}
            local prepared = ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-admission-drift", receipt_key = "admission-drift"}))
            test.eq(prepared.application_admission_digest, (assert(bounds.object(world.application_admission))).digest)
            world.application_admission = admission(exact.digest, string.rep("b", 64), nil, workspace)
            local refused = owner.step(config, "intent-admission-drift", "admission-drift")
            test.is_false(refused.ok)
            test.eq(refused.code, "CONFLICT")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("rebuilds the composed admission from immutable intent for apply and cold recovery", function()
            local workspace = "workspace-admission-recovery"
            local plans = assert(plan_store.open("bee.gov:plan_test_db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee.gov:activation_test_db", "node-owner", workspace))
            local entry = {id = "demo:admission-recovery", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local frozen = admission(exact.digest, SHA, nil, workspace)
            local applied = false
            local apply_count = 0
            local function config(): owner.Config
                return {plans = plans, activations = activations,
                    resolver = shifting_resolver(entry, {revision = 4, digest = SHA, application_admission = frozen}),
                    approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                    overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                    matches = function(_overlay: string, entries: unknown, admission_blob: unknown?, _intent: unknown): (boolean?, string?)
                        test.eq(#(principals.items(entries)), 1)
                        local blob = assert(bounds.object(admission_blob))
                        test.eq(blob.bytes, frozen.bytes)
                        test.eq(blob.digest, frozen.digest)
                        return applied, nil
                    end,
                    apply = function(_overlay: string, entries: unknown, admission_blob: unknown?, _intent: unknown): ({[string]: unknown}?, string?)
                        test.eq(#(principals.items(entries)), 1)
                        local blob = assert(bounds.object(admission_blob))
                        test.eq(blob.bytes, frozen.bytes)
                        test.eq(blob.digest, frozen.digest)
                        applied, apply_count = true, apply_count + 1
                        return {changed = true}, nil
                    end}
            end
            ok(owner.prepare(config(), {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-admission-recovery", receipt_key = "admission-recovery"}))
            test.eq(ok(owner.step(config(), "intent-admission-recovery", "admission-recovery")).phase, "consuming")
            test.eq(ok(owner.step(config(), "intent-admission-recovery", "admission-recovery")).phase, "authorized")
            test.eq(ok(owner.step(config(), "intent-admission-recovery", "admission-recovery")).phase, "applying")
            test.eq(ok(owner.step(config(), "intent-admission-recovery", "admission-recovery")).outcome, "applied")
            test.eq(apply_count, 1)
            applied = false
            local recovered = ok(owner.recover(config(), "admission-recovery"))
            test.is_true(recovered.recovered == true)
            test.eq(apply_count, 2)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("repairs a partial overlay when its installed capability grant matches the activation", function()
            local workspace = "workspace-partial-grant-recovery"
            local plans = assert(plan_store.open("bee.gov:plan_test_db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee.gov:activation_test_db", "node-owner", workspace))
            local entry = {id = "demo:grant-recovery", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local vocabulary: capability_model.Vocabulary = {revision = 1, never = {}, capabilities = {}}
            local proposal, proposal_error = capability_grants.propose(vocabulary, "bee.gov:test-overlay",
                "demo:grant-recovery", {}, nil)
            if not proposal then error(tostring(proposal_error)) end
            local review, review_error = capability_grants.diff(vocabulary, nil, proposal)
            if not review then error(tostring(review_error)) end
            local world: ResolverWorld = {revision = 4, digest = SHA,
                capability = {kind = "new", proposal = proposal, review = review}}
            local application_entry_present, apply_count = false, 0
            local installed_evidence: preflight.CapabilityEvidence? = nil
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world), approvals = approvals(), actor_id = "host-a",
                consumer_id = "destination-host", overlay_owner = "bee.gov:test-overlay",
                approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?)
                    return application_entry_present, nil
                end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, intent_raw: unknown): ({[string]: unknown}?, string?)
                    if installed_evidence == nil then
                        local intent = assert(bounds.object(intent_raw))
                        local record, record_error = capability_grants.record("bee.gov:test-overlay", workspace,
                            "demo:grant-recovery", proposal, intent.approval_id, 1, intent.artifact_digest,
                            intent.version)
                        if not record then return nil, tostring(record_error) end
                        local installed, decode_error = capability_grants.decode(record, "bee.gov:test-overlay",
                            workspace, "demo:grant-recovery", vocabulary)
                        if not installed then return nil, tostring(decode_error) end
                        local installed_review, installed_review_error = capability_grants.diff(vocabulary, installed, proposal)
                        if not installed_review then return nil, tostring(installed_review_error) end
                        installed_evidence = {kind = "installed", proposal = proposal, installed = installed,
                            review = installed_review}
                        world.capability = installed_evidence
                    end
                    application_entry_present, apply_count = true, apply_count + 1
                    return {changed = true}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-partial-grant", receipt_key = "partial-grant"}))
            test.eq(ok(owner.step(config, "intent-partial-grant", "partial-grant")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-partial-grant", "partial-grant")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-partial-grant", "partial-grant")).phase, "applying")
            test.eq(ok(owner.step(config, "intent-partial-grant", "partial-grant")).outcome, "applied")
            test.is_true(installed_evidence ~= nil)
            application_entry_present = false
            local restored = ok(owner.recover(config, "partial-grant"))
            test.is_true(restored.recovered == true)
            test.is_true(application_entry_present)
            test.eq(apply_count, 2)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("refuses an application admission for another overlay before storing or requesting approval", function()
            local workspace = "workspace-admission-owner"
            local plans = assert(plan_store.open("bee.gov:plan_test_db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee.gov:activation_test_db", "node-owner", workspace))
            local entry = {id = "demo:admission-owner", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local world: ResolverWorld = {revision = 4, digest = SHA,
                application_admission = admission(exact.digest, SHA, "bee.gov:other-overlay", workspace)}
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world), approvals = approvals(), actor_id = "host-a",
                consumer_id = "destination-host", overlay_owner = "bee.gov:test-overlay",
                approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?) return false, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?) return {changed = true}, nil end}
            local refused = owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-admission-owner", receipt_key = "admission-owner"})
            test.is_false(refused.ok)
            test.eq(refused.code, "CONFLICT")
            test.eq(activation_store.get(activations, "intent-admission-owner").code, "NOT_FOUND")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("reconciles lost consume and apply replies without following a newer plan", function()
            local plans, plan_error = plan_store.open("bee.gov:plan_test_db", "node-owner", "workspace-crash")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee.gov:activation_test_db", "node-owner", "workspace-crash")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local applied = false
            local first_apply = true
            local fail_restore = false
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolver(entry),
                approvals = lossy_approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?)
                    if fail_restore then return nil, "overlay restore failed" end
                    applied = true
                    if first_apply then first_apply = false; return nil, "overlay reply was lost" end
                    return {changed = false}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-crash", receipt_key = "activation-crash"}))
            test.eq(ok(owner.step(config, "intent-crash", "activation-crash")).phase, "consuming")
            test.eq(owner.step(config, "intent-crash", "activation-crash").code, "UNAVAILABLE")
            local v2 = assert(artifact.create({{id = "demo:run", kind = "function.lua", data = {source = "return 'v2'"}}}))
            selected_plan(plans, "v2", {bytes = v2.bytes, digest = v2.digest})
            test.eq(ok(owner.step(config, "intent-crash", "activation-crash")).phase, "authorized")
            test.eq(ok(owner.recover(config, "activation-crash")).phase, "applying")
            local uncertain = owner.recover(config, "activation-crash")
            test.eq(uncertain.code, "UNCERTAIN")
            local settled = ok(owner.recover(config, "activation-crash"))
            test.eq(settled.outcome, "applied")
            test.eq(settled.version, "v1")
            applied = false
            local restored = ok(owner.recover(config, "activation-crash"))
            test.is_true(restored.recovered == true)
            test.is_true(applied)
            applied, fail_restore = false, true
            test.eq(owner.recover(config, "activation-crash").code, "UNCERTAIN")
            fail_restore = false
            local recovered_again = ok(owner.recover(config, "activation-crash"))
            test.eq(recovered_again.outcome, "applied")
            test.is_true(applied)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("settles an in-flight effect before authorizing v2 and fences historical v1 recovery", function()
            local plans, plan_error = plan_store.open("bee.gov:plan_test_db", "node-owner", "workspace-version-fence")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee.gov:activation_test_db", "node-owner", "workspace-version-fence")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'stable'"}}
            local exact = assert(artifact.create({entry}))
            local applied = false
            local apply_count = 0
            local config: owner.Config = {plans = plans, activations = activations, resolver = resolver(entry),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?)
                    applied, apply_count = true, apply_count + 1
                    return {changed = true}, nil
                end}

            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-fenced-v1", receipt_key = "fenced-v1"}))
            test.eq(ok(owner.step(config, "intent-fenced-v1", "fenced-v1")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-fenced-v1", "fenced-v1")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-fenced-v1", "fenced-v1")).phase, "applying")

            selected_plan(plans, "v2", {bytes = exact.bytes, digest = exact.digest})
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v2", intent_id = "intent-fenced-v2", receipt_key = "fenced-v2"}))
            test.eq(ok(owner.step(config, "intent-fenced-v2", "fenced-v2")).phase, "consuming")
            local overlap = owner.step(config, "intent-fenced-v2", "fenced-v2")
            test.eq(overlap.code, "CONFLICT")
            test.eq(ok(owner.desired(config)).intent_id, "intent-fenced-v1")

            test.eq(ok(owner.step(config, "intent-fenced-v1", "fenced-v1")).outcome, "applied")
            test.eq(apply_count, 1)
            applied = false
            test.eq(ok(owner.step(config, "intent-fenced-v2", "fenced-v2")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-fenced-v2", "fenced-v2")).phase, "applying")
            test.eq(ok(owner.step(config, "intent-fenced-v2", "fenced-v2")).outcome, "applied")
            test.eq(apply_count, 2)

            applied = false
            local historical = owner.step(config, "intent-fenced-v1", "fenced-v1")
            test.eq(historical.code, "CONFLICT")
            test.is_false(applied)
            test.eq(apply_count, 2)
            test.eq(ok(owner.desired(config)).intent_id, "intent-fenced-v2")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("refuses an authorized apply when the composed base changed under review", function()
            local plans, plan_error = plan_store.open("bee.gov:plan_test_db", "node-owner", "workspace-composed-refusal")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee.gov:activation_test_db", "node-owner", "workspace-composed-refusal")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local world: {revision: integer, digest: string} = {revision = 4, digest = SHA}
            local applied = false
            local apply_count = 0
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?)
                    applied, apply_count = true, apply_count + 1
                    return {changed = true}, nil
                end}
            local prepared = owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-composed", receipt_key = "composed-v1"})
            test.eq(ok(prepared).phase, "approval_bound")
            test.eq(ok(owner.step(config, "intent-composed", "composed-v1")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-composed", "composed-v1")).phase, "authorized")
            world.revision, world.digest = 5, SHA_B
            local refused = owner.step(config, "intent-composed", "composed-v1")
            test.eq(refused.code, "CONFLICT")
            test.is_true(tostring(refused.message):find("composed registry base", 1, true) ~= nil)
            test.is_false(applied)
            test.eq(apply_count, 0)
            world.revision, world.digest = 4, SHA
            test.eq(ok(owner.step(config, "intent-composed", "composed-v1")).phase, "applying")
            test.eq(ok(owner.step(config, "intent-composed", "composed-v1")).outcome, "applied")
            test.eq(apply_count, 1)
            local again = ok(owner.step(config, "intent-composed", "composed-v1"))
            test.eq(again.outcome, "applied")
            test.eq(apply_count, 1)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("leaves an apply uncertain when the base moves during the apply", function()
            local plans, plan_error = plan_store.open("bee.gov:plan_test_db", "node-owner", "workspace-composed-apply")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee.gov:activation_test_db", "node-owner", "workspace-composed-apply")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local world: {revision: integer, digest: string} = {revision = 4, digest = SHA}
            local applied = false
            local apply_count = 0
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world),
                approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?)
                    applied, apply_count = true, apply_count + 1
                    world.revision, world.digest = 5, SHA_B
                    return {changed = true}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-composed-apply", receipt_key = "composed-apply-v1"}))
            test.eq(ok(owner.step(config, "intent-composed-apply", "composed-apply-v1")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-composed-apply", "composed-apply-v1")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-composed-apply", "composed-apply-v1")).phase, "applying")
            local outcome = owner.step(config, "intent-composed-apply", "composed-apply-v1")
            test.eq(outcome.code, "UNCERTAIN")
            test.is_true(tostring(outcome.message):find("composed registry base", 1, true) ~= nil)
            test.is_true(applied)
            test.eq(apply_count, 1)
            local later = owner.recover(config, "composed-apply-v1")
            test.eq(later.code, "CONFLICT")
            test.is_true(tostring(later.message):find("composed registry base", 1, true) ~= nil)
            test.eq(apply_count, 1)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)

        test.it("reconciles an interrupted apply after a restart without duplicating it", function()
            local plans, plan_error = plan_store.open("bee.gov:plan_test_db", "node-owner", "workspace-composed-restart")
            if not plans then error(tostring(plan_error)) end
            local activations, activation_error = activation_store.open("bee.gov:activation_test_db", "node-owner", "workspace-composed-restart")
            if not activations then error(tostring(activation_error)) end
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return 'v1'"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local world: {revision: integer, digest: string} = {revision = 4, digest = SHA}
            local applied = false
            local apply_count = 0
            local function config_with(plan_handle: plan_store.Store, activation_handle: activation_store.Store): owner.Config
                return {plans = plan_handle, activations = activation_handle,
                    resolver = shifting_resolver(entry, world),
                    approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                    overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                    matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?) return applied, nil end,
                    apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?)
                        applied, apply_count = true, apply_count + 1
                        return {changed = true}, nil
                    end}
            end
            ok(owner.prepare(config_with(plans, activations), {source_node = "source-a",
                source_workspace = "app-a", version = "v1", intent_id = "intent-composed-restart",
                receipt_key = "composed-restart-v1"}))
            test.eq(ok(owner.step(config_with(plans, activations), "intent-composed-restart", "composed-restart-v1")).phase, "consuming")
            test.eq(ok(owner.step(config_with(plans, activations), "intent-composed-restart", "composed-restart-v1")).phase, "authorized")
            test.eq(ok(owner.step(config_with(plans, activations), "intent-composed-restart", "composed-restart-v1")).phase, "applying")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
            local reopened_plans, reopen_error = plan_store.open("bee.gov:plan_test_db", "node-owner", "workspace-composed-restart")
            if not reopened_plans then error(tostring(reopen_error)) end
            local reopened_activations, reopen_activation_error = activation_store.open("bee.gov:activation_test_db", "node-owner", "workspace-composed-restart")
            if not reopened_activations then error(tostring(reopen_activation_error)) end
            local settled = ok(owner.recover(config_with(reopened_plans, reopened_activations), "composed-restart-v1"))
            test.eq(settled.outcome, "applied")
            test.eq(apply_count, 1)
            assert(activation_store.close(reopened_activations))
            assert(plan_store.close(reopened_plans))
            local again_plans = assert(plan_store.open("bee.gov:plan_test_db", "node-owner", "workspace-composed-restart"))
            local again_activations = assert(activation_store.open("bee.gov:activation_test_db", "node-owner", "workspace-composed-restart"))
            local replayed = ok(owner.recover(config_with(again_plans, again_activations), "composed-restart-v1"))
            test.eq(replayed.outcome, "applied")
            test.eq(apply_count, 1)
            world.revision, world.digest = 5, SHA_B
            local preserved = ok(owner.recover(config_with(again_plans, again_activations), "composed-restart-v1"))
            test.eq(preserved.outcome, "applied")
            test.eq(apply_count, 1)
            applied = false
            local restored = ok(owner.recover(config_with(again_plans, again_activations), "composed-restart-v1"))
            test.eq(restored.outcome, "applied")
            test.is_true(restored.recovered == true)
            test.eq(apply_count, 2)
            applied = false
            world.blocked = true
            local blocked = owner.recover(config_with(again_plans, again_activations), "composed-restart-v1")
            test.eq(blocked.code, "BLOCKED")
            test.eq(apply_count, 2)
            assert(activation_store.close(again_activations))
            assert(plan_store.close(again_plans))
        end)

        test.it("completes captured migrations before exposing the application overlay", function()
            local plans = assert(plan_store.open("bee.gov:plan_test_db", "node-owner", "workspace-migration-owner"))
            local activations = assert(activation_store.open("bee.gov:activation_test_db", "node-owner", "workspace-migration-owner"))
            local entry = {id = "demo:001", kind = "function.lua",
                meta = {type = "migration", target_db = "host:db", ordinal = 1},
                data = {source = "return true", modules = {}}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local state: {[string]: unknown} = {staged = false, executed = false, applied = false}
            local effect = {
                matches = function(_owner: string, _work: migration_work.Work): (boolean?, string?) return state.staged == true, nil end,
                prepare = function(_owner: string, _work: migration_work.Work): ({[string]: unknown}?, string?)
                    state.staged = true; return {changed = true}, nil
                end,
                clear = function(_owner: string): ({[string]: unknown}?, string?)
                    state.staged = false; return {changed = true}, nil
                end,
                cleared = function(_owner: string): (boolean?, string?) return state.staged ~= true, nil end,
                execute = function(_work: migration_work.Work): ({bytes: string, digest: string}?, boolean, string?)
                    state.executed = true
                    local bytes = assert(canonical.encode({schema_revision = "bee.governance-migration-receipt@1",
                        rows = {{id = "demo:001", target_db = "host:db", module = "demo/app", status = "applied"}}}))
                    return {bytes = bytes, digest = assert(hash.sha256(bytes))}, true, nil
                end,
            }
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = migration_resolver(entry, state), approvals = approvals(), actor_id = "host-a",
                consumer_id = "destination-host", overlay_owner = "bee.gov:migration-overlay",
                approval_policy = "local-install", migrations = effect,
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?) return state.applied == true, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?)
                    test.is_true(state.executed == true)
                    test.is_true(state.staged ~= true)
                    state.applied = true
                    return {changed = true}, nil
                end}
            ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a", version = "v1",
                intent_id = "intent-migration", receipt_key = "migration"}))
            test.eq(ok(owner.step(config, "intent-migration", "migration")).phase, "consuming")
            test.eq(ok(owner.step(config, "intent-migration", "migration")).phase, "authorized")
            test.eq(ok(owner.step(config, "intent-migration", "migration")).phase, "applying")
            state.policy_digest = SHA_B
            local changed_policy = owner.step(config, "intent-migration", "migration")
            test.eq(changed_policy.code, "CONFLICT")
            test.is_true(tostring(changed_policy.message):find("database policy", 1, true) ~= nil)
            test.is_false(state.executed == true)
            state.policy_digest = SHA
            local migrated = ok(owner.step(config, "intent-migration", "migration"))
            test.is_true(migrated.migrations_completed == true)
            test.is_false(state.applied == true)
            test.is_true(ok(owner.step(config, "intent-migration", "migration")).recovered == true)
            test.is_false(state.staged == true)
            local settled = ok(owner.step(config, "intent-migration", "migration"))
            test.eq(settled.outcome, "applied")
            test.is_true(state.applied == true)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
    end)
end

return test.run_cases(define_tests)
