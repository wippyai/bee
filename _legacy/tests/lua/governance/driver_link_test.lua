-- SPDX-License-Identifier: MIT
local test = require("test")
local registry = require("registry")
local security = require("security")
local funcs = require("funcs")
local materializer = require("materializer")
local activation = require("activation")
local bounds = require("bounds")
local resolver = require("resolver")
local store = require("activation_store")
local artifact = require("artifact")
local canonical = require("canonical")
local hash = require("hash")
local system = require("system")
local resources = require("resources")
local service = require("destination_service")
local OWNER = "bee.gov:driver-link-proof"
local function values(): {unknown}
    local entry = assert(registry.get(activation.TARGET))
    return assert(bounds.dense_list(entry.data.bindings, 128, "driver bindings"))
end
local function define_tests()
    test.describe("Approved driver host selection", function()
        test.it("reads an exact consumed host-selected owner without requiring a driver owner prefix", function()
            local node = assert(system.node.id())
            local workspace = "driver-owner-profile"
            local binding_id = "bee.driver.ownerproof.binding:binding"
            local builtin = assert(registry.get("bee.driver.claude.binding:binding"))
            local entries: {{[string]: unknown}} = {
                {id = binding_id, kind = "contract.binding", meta = {type = "harness.driver"}, data = builtin.data},
                {id = "bee.driver.ownerproof.binding:activation", kind = "ns.requirement", meta = {value_kind = "contract.binding"},
                    data = {default = binding_id, targets = {{entry = activation.TARGET, path = ".bindings +="}}}},
            }
            local captured = assert(artifact.create(entries))
            local original = assert(registry.get("bee.env:gov_activation_profiles"))
            local function configure(owner: string)
                local entry = assert(registry.get(original.id))
                entry.data = {profiles = {{workspace_id = workspace, source_node = node,
                    source_workspace = "driver.ownerproof", component = "bee.driver.ownerproof",
                    overlay_owner = owner, approval_policy = "workspace-application-delivery", resolver = "overlay",
                    allow = {packages = {"bee.driver.ownerproof"}, namespaces = {"bee.driver.ownerproof.binding"},
                        kinds = {"contract.binding", "ns.requirement"}, databases = {}, grants = {}, modules = {}}}}}
                local changes = assert(registry.snapshot()):changes()
                assert(changes:update(entry))
                assert(changes:apply())
            end
            local function selected(): boolean
                for _, id in ipairs(assert(service.driver_bindings())) do if id == binding_id then return true end end
                return false
            end
            local state = assert(store.open(assert(resources.database()), node, workspace))
            local function record(input: {[string]: unknown}): {[string]: unknown}
                local reply = store.call(state, "driver-proof", input)
                assert(reply.ok, reply.message)
                return assert(bounds.object(reply.value))
            end
            local function blob(bytes: string): {bytes: string, digest: string}
                return {bytes = bytes, digest = assert(hash.sha256(bytes))}
            end
            local ok, problem = pcall(function()
                configure(OWNER)
                assert(materializer.reconcile(OWNER, entries))
                test.is_false(selected(), "an overlay without consumed approval is not admitted")
                local digest = string.rep("a", 64)
                local prepared = record({operation = "prepare_activation", intent_id = "driver-owner-intent",
                    expected_revision = 0, idempotency_key = "prepare-driver-owner", overlay_owner = OWNER,
                    source_node = node, source_workspace = "driver.ownerproof", version = "v1",
                    plan_digest = digest, plan_revision = 1, selection_revision = 1, artifact = captured,
                    resolution = blob("resolution"), preflight = blob("preflight"),
                    migration_work = blob(assert(canonical.encode({schema_revision = "bee.governance-migration-work@2",
                        destination_node = node, source_node = node, base_revision = 0, base_digest = digest,
                        policy_digest = digest, candidate_digest = digest, artifact_digest = captured.digest,
                        plan_digest = digest, migrations = {}, databases = {}})))})
                local bound = record({operation = "bind_approval", intent_id = prepared.intent_id,
                    expected_revision = prepared.revision, idempotency_key = "bind-driver-owner",
                    approval_id = "driver-owner-approval", approval_proposal_digest = digest, approval_owner_incarnation = 1})
                local consuming = record({operation = "begin_consume", intent_id = prepared.intent_id,
                    expected_revision = bound.revision, idempotency_key = "consume-driver-owner"})
                record({operation = "record_consumption", intent_id = prepared.intent_id,
                    expected_revision = consuming.revision, idempotency_key = "receipt-driver-owner",
                    consumer_id = "bee.gov.activation", proposal_digest = digest, effect_key = prepared.effect_key})
                test.is_true(selected(), "the host-selected owner and consumed artifact admit this exact binding")
                configure("bee.gov:another-owner")
                test.is_false(selected(), "a different host-selected owner does not admit the binding")
                configure(OWNER)
                assert(materializer.reconcile(OWNER, {}))
                test.is_false(selected(), "consumption without the matching live artifact is not admitted")
            end)
            assert(store.close(state))
            assert(materializer.reconcile(OWNER, {}))
            local changes = assert(registry.snapshot()):changes()
            assert(changes:update(original))
            assert(changes:apply())
            if not ok then error(tostring(problem)) end
        end)
        test.it("keeps raw requirements declarative and derives owned approved bindings", function()
            local baseline = values()
            local builtin = assert(registry.get("bee.driver.claude.binding:binding"))
            local entries: {{[string]: unknown}} = {
                {id = "bee.driver.link.binding:binding", kind = "contract.binding", meta = {type = "harness.driver"}, data = builtin.data},
                {id = "bee.driver.link.binding:activation", kind = "ns.requirement", meta = {value_kind = "contract.binding"},
                    data = {default = "bee.driver.link.binding:binding", targets = {{entry = activation.TARGET, path = ".bindings +="}}}},
            }
            assert(materializer.reconcile(OWNER, entries))
            local selected, problem = activation.bindings(entries)
            test.is_nil(problem)
            test.eq(#assert(selected), 1)
            test.eq(assert(selected)[1], "bee.driver.link.binding:binding")
            local active, active_error = resolver.active(assert(resolver.pin()))
            test.is_nil(active_error)
            test.is_nil(assert(active)["bee.driver.link.binding:binding"])
            local unlinked = values()
            test.eq(#unlinked, #baseline)
            for index, value in ipairs(baseline) do test.eq(unlinked[index], value) end
            assert(materializer.reconcile(OWNER, {}))
            test.eq(#assert(activation.bindings({})), 0)
        end)
        test.it("lets each owning launch scope read admitted drivers", function()
            local probe_policy = assert(security.policy("bee.gov:admission_probe_call"))
            for _, id in ipairs({"bee.sessions.security:owner_admission_policy", "bee.executor.external.security:driver_placement_calls",
                "bee.placement.native.security:placement_store_policy", "bee.harness.security:launch_locate_probe_policy",
                "bee.harness.security:harness_setup_policy", "bee.harness.security:profile_store_policy"}) do
                local policy = assert(security.policy(id))
                local scope = security.new_scope({policy, probe_policy})
                local caller = funcs.new():with_scope(scope)
                local allowed, problem = caller:call("bee.gov:admission_scope_probe")
                test.is_nil(problem)
                if allowed ~= true then error("driver admission reader is denied by " .. id) end
                local bindings, read_error = caller:call("bee.gov.binding:driver_bindings")
                test.is_nil(read_error)
                test.is_true(bounds.ids(bindings, true) ~= nil)
            end
        end)
        test.it("refuses a host-list replacement and a foreign binding before selection", function()
            for _, path in ipairs({".bindings", ".bindings +="}) do
                local entries = {{id = "bee.driver.link.binding:activation", kind = "ns.requirement",
                    data = {default = "bee.driver.claude.binding:binding", targets = {{entry = activation.TARGET, path = path}}}}}
                local result = activation.bindings(entries)
                test.is_nil(result)
            end
        end)
    end)
end
return test.run_cases(define_tests)
