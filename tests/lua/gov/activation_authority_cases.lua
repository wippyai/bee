-- MIT. Focused activation owner test cases.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local hash = require("hash")
local canonical = require("canonical")
local artifact = require("artifact")
local plan_store = require("plan_store")
local activation_store = require("activation_store")
local owner = require("activation_owner")
local lease_store = require("lease_store")
local application_admission = require("application_admission")
local capability_grants = require("capability_grants")
local support = require("support")
local SHA = support.SHA
type ResolverWorld = support.ResolverWorld
local expect_code = support.expect_code
local ok = support.ok
local migration_effect = support.migration_effect
local selected_plan = support.selected_plan
local admission = support.admission
local installed_capability = support.installed_capability
local shifting_resolver = support.shifting_resolver
local resolver = support.resolver
local approvals = support.approvals
local definite_failure_test = support.definite_failure_test
local queued_failure_test = support.queued_failure_test
local LEASE_NARROW = support.LEASE_NARROW
local LEASE_OUTSIDE = support.LEASE_OUTSIDE
local widening_capability = support.widening_capability
local lease_config = support.lease_config
local grant_lease = support.grant_lease
local function authority_tests()
    test.describe("Governance activation owner", function()
        test.it("settles a definite load failure once with its location", function() definite_failure_test(false) end)
        test.it("settles an admitted syntax error from the old preflight without invoking apply", function()
            definite_failure_test(true)
        end)
        test.it("hands the slot to an already-consuming successor after a definite failure", queued_failure_test)
        for _, phase in ipairs({"statement", "commit"}) do
            test.it("reports the SQLite " .. phase .. " cause through the owner", function()
                local workspace = "workspace-sql-cause-" .. phase
                local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
                local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
                local entry = {id = "demo:run", kind = "function.lua", data = {source = "return true"}}
                local exact = assert(artifact.create({entry}))
                selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
                local config: owner.Config = {plans = plans, activations = activations,
                    resolver = shifting_resolver(entry, {revision = 4, digest = SHA}),
                    approvals = approvals(), actor_id = "host-a", consumer_id = "destination-host",
                    overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install", migrations = migration_effect(),
                    matches = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): (boolean?, string?, boolean?) return false, nil end,
                    apply = function(_overlay: string, _entries: unknown, _admission: unknown?, _intent: unknown): ({[string]: unknown}?, string?, boolean?)
                        error("failed activation must never reach apply")
                    end}
                local function execute(statement: string)
                    local _, err = activations.db:execute(statement)
                    if err then error(tostring(err)) end
                end
                local cause: string
                if phase == "statement" then
                    execute([[CREATE TRIGGER bee_test_activation_cause BEFORE INSERT ON bee_governance_activation_intents
                        WHEN NEW.workspace_id = 'workspace-sql-cause-statement'
                        BEGIN SELECT RAISE(ABORT, 'injected activation SQLite step'); END]])
                    cause = "injected activation SQLite step"
                else
                    execute("CREATE TABLE bee_test_activation_parent (id INTEGER PRIMARY KEY)")
                    execute([[CREATE TABLE bee_test_activation_child (parent_id INTEGER REFERENCES bee_test_activation_parent(id)
                        DEFERRABLE INITIALLY DEFERRED)]])
                    execute([[CREATE TRIGGER bee_test_activation_cause AFTER INSERT ON bee_governance_activation_intents
                        WHEN NEW.workspace_id = 'workspace-sql-cause-commit'
                        BEGIN INSERT INTO bee_test_activation_child VALUES (1); END]])
                    cause = "FOREIGN KEY constraint failed"
                end
                local result = owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                    version = "v1", intent_id = "intent-sql-cause", receipt_key = "sql-cause"})
                execute("DROP TRIGGER bee_test_activation_cause")
                if phase == "commit" then
                    execute("DROP TABLE bee_test_activation_child")
                    execute("DROP TABLE bee_test_activation_parent")
                end
                expect_code(activation_store.get(activations, "intent-sql-cause"), "NOT_FOUND")
                assert(activation_store.close(activations))
                assert(plan_store.close(plans))
                expect_code(result, "INTERNAL")
                test.is_true(tostring(result.message):find(cause, 1, true) ~= nil, tostring(result.message))
                local succeeded, output = pcall(function() ok(result) end)
                test.is_false(succeeded)
                test.is_true(tostring(output):find(cause, 1, true) ~= nil, tostring(output))
                local matched, diagnostic = pcall(function() expect_code(result, "UNEXPECTED") end)
                test.is_false(matched)
                test.is_true(tostring(diagnostic):find(cause, 1, true) ~= nil, tostring(diagnostic))
            end)
        end

        test.it("reuses a contained live grant without requesting a permission decision", function()
            local workspace = "workspace-contained-grant"
            local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return true"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
            local evidence = installed_capability(nil)
            if evidence.kind ~= "installed" then error("installed capability evidence is missing") end
            local world: ResolverWorld = {revision = 4, digest = SHA,
                capability = evidence, application_admission = admission(exact.digest, SHA, nil, workspace)}
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
                    _intent: unknown): (boolean?, string?, boolean?) return applied, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?,
                    _intent: unknown): ({[string]: unknown}?, string?, boolean?)
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
            applied = false
            world.capability = {kind = "new", proposal = evidence.proposal, review = evidence.review}
            test.is_true(ok(owner.recover(config, "contained-cold")).recovered == true)
            test.is_true(applied)
            test.eq(requests, 0)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("shows a widening delta and leaves a refused decision unapplied", function()
            local workspace = "workspace-widened-grant"
            local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
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
                    _intent: unknown): (boolean?, string?, boolean?) return false, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?,
                    _intent: unknown): ({[string]: unknown}?, string?, boolean?)
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
            expect_code(owner.step(config, "intent-widened", "widened"), "DENIED")
            test.is_false(applied)
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("asks the person about the version under the name of the agent that made it", function()
            local workspace = "workspace-made-by"
            local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
            local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
            local entry = {id = "demo:run", kind = "function.lua", data = {source = "return true"}}
            local exact = assert(artifact.create({entry}))
            selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest}, "Claude Code")
            local review: capability_grants.Review = {added = {}, widened = {}, narrowed = {}, removed = {}, changed = {},
                requires_approval = true, revocation = {grants = {}, fenced_attempts = {}},
                lines = {"widened: Read owned threads"}, resolved = {"Read owned threads"},
                delta = {"widened: Read owned threads"}}
            local world: ResolverWorld = {revision = 4, digest = SHA, capability = installed_capability(review)}
            local prompt: string? = nil
            local executor = {}
            function executor.call(self: owner.Executor, method: string, request: unknown): (unknown?, unknown?)
                local input = assert(bounds.object(request))
                local proposal = assert(bounds.object(input.proposal))
                prompt = tostring((assert(bounds.object(input.prompt))).text)
                return {ok = true, value = {approval_id = "made-by-approval", proposal = proposal,
                    proposal_digest = assert(hash.sha256(assert(canonical.encode(proposal)))),
                    owner_incarnation = 3}}, nil
            end
            local config: owner.Config = {plans = plans, activations = activations,
                resolver = shifting_resolver(entry, world), approvals = executor,
                actor_id = "host-a", consumer_id = "destination-host",
                overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install",
                migrations = migration_effect(),
                matches = function(_overlay: string, _entries: unknown, _admission: unknown?,
                    _intent: unknown): (boolean?, string?, boolean?) return false, nil end,
                apply = function(_overlay: string, _entries: unknown, _admission: unknown?,
                    _intent: unknown): ({[string]: unknown}?, string?, boolean?) return {changed = true}, nil end}
            test.eq(ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                version = "v1", intent_id = "intent-made-by", receipt_key = "made-by"})).phase, "approval_bound")
            local asked = tostring(prompt)
            test.eq(asked:sub(1, asked:find("?", 1, true)), "Install app-a v1 (made by Claude Code · from bee source-a)?")
            assert(activation_store.close(activations))
            assert(plan_store.close(plans))
        end)
        test.it("ends an activation whose approval was denied or expired and closes its request", function()
            for _, ending in ipairs({"denied", "expired", "withdrawn", "superseded", "invalidated"}) do
                local projected = ending == "superseded" and "withdrawn" or (ending == "invalidated" and "expired" or ending)
                local workspace = "workspace-ended-" .. ending
                local plans = assert(plan_store.open("bee:db", "node-owner", workspace))
                local activations = assert(activation_store.open("bee:db", "node-owner", workspace))
                local entry = {id = "demo:run", kind = "function.lua", data = {source = "return true"}}
                local exact = assert(artifact.create({entry}))
                selected_plan(plans, "v1", {bytes = exact.bytes, digest = exact.digest})
                local review: capability_grants.Review = {added = {}, widened = {}, narrowed = {}, removed = {}, changed = {},
                    requires_approval = true, revocation = {grants = {}, fenced_attempts = {}},
                    lines = {"widened: Read owned threads"}, resolved = {"Read owned threads"},
                    delta = {"widened: Read owned threads"}}
                local world: ResolverWorld = {revision = 4, digest = SHA, capability = installed_capability(review)}
                local requested: {[string]: unknown}? = nil
                local closed = 0
                local executor = {}
                function executor.call(self: owner.Executor, method: string, request: unknown): (unknown?, unknown?)
                    local input = assert(bounds.object(request))
                    if method == "bee.approvals.binding:request" then
                        local proposal = assert(bounds.object(input.proposal))
                        requested = {approval_id = "ended-" .. ending, proposal = proposal,
                            proposal_digest = assert(hash.sha256(assert(canonical.encode(proposal)))), owner_incarnation = 3}
                        return {ok = true, value = requested}, nil
                    end
                    local shown = assert(requested)
                    if method == "bee.approvals.binding:read" then
                        return {ok = true, value = {approval_id = shown.approval_id, proposal_digest = shown.proposal_digest,
                            state = ending == "denied" and "decided" or ending,
                            decision = ending == "denied" and "denied" or nil, effect = {state = "canceled"}}}, nil
                    end
                    if method == "bee.approvals.binding:effect" then
                        test.eq(input.operation, "complete")
                        test.eq(input.approval_id, shown.approval_id)
                        closed = closed + 1
                        return {ok = true, value = {approval_id = shown.approval_id}}, nil
                    end
                    return {ok = false, error = {code = "DENIED", message = "the person denied it"}}, nil
                end
                local config: owner.Config = {plans = plans, activations = activations,
                    resolver = shifting_resolver(entry, world), approvals = executor,
                    actor_id = "host-a", consumer_id = "destination-host",
                    overlay_owner = "bee.gov:test-overlay", approval_policy = "local-install",
                    migrations = migration_effect(),
                    matches = function(_overlay: string, _entries: unknown, _admission: unknown?,
                        _intent: unknown): (boolean?, string?, boolean?) return false, nil end,
                    apply = function(_overlay: string, _entries: unknown, _admission: unknown?,
                        _intent: unknown): ({[string]: unknown}?, string?, boolean?) return {changed = true}, nil end}
                local prepared = ok(owner.prepare(config, {source_node = "source-a", source_workspace = "app-a",
                    version = "v1", intent_id = "intent-ended", receipt_key = "ended"}))
                test.eq(prepared.phase, "approval_bound")
                if ending == "denied" then test.eq(ok(owner.step(config, "intent-ended", "ended")).phase, "consuming") end
                local ended = ok(owner.close(config, "intent-ended", "ended"))
                test.eq(ended.phase, "settled")
                test.eq(ended.outcome, projected)
                test.is_nil(ended.desired_intent_id)
                test.eq(closed, 1)
                -- Closing again finds it settled and closes the request again, which replays.
                test.eq(ok(owner.close(config, "intent-ended", "ended")).outcome, projected)
                test.eq(closed, 2)
                assert(activation_store.close(activations))
                assert(plan_store.close(plans))
            end
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
            expect_code(owner.step(config, "intent-fenced", "fenced"), "DENIED")
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
            local _, update_error = leases.db:execute("UPDATE bee_governance_lease_uses SET approval_id = 'another-approval'")
            if update_error then error(tostring(update_error)) end
            expect_code(owner.step(config, "intent-mismatch", "mismatch"), "CONFLICT")
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
    end)
end

return {define = authority_tests}
