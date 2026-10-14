-- SPDX-License-Identifier: MIT
local test = require("test")
local environment = require("environment")
local legacy = require("legacy")
local grants = require("grants")
local bounds = require("bounds")
local schema = require("schema")
local service = require("service")
local registry = require("registry")
local uuid = require("uuid")
local clock = require("clock")
local M = {}
function M.run()
    test.describe("Docker first-use environment admission", function()
        test.it("the original approval creates persistent consent and central revocation stops future admission",function()
            local policies = assert(registry.get("bee.security.approvals:approver_policies"))
            local data = assert(bounds.object(policies.data))
            local rows = assert(bounds.array(data.policies,64))
            rows[#rows + 1] = {name = "phase3-docker",approvers = {"docker-person"},max_ttl_ms = 60000,allow_permanent = true}
            data.policies = rows; policies.data = data
            local changes = registry.snapshot():changes(); assert(changes:update(policies)); assert(changes:apply())
            local db = schema.open("bee.approvals:test_db","bee.approvals.migrations")
            assert(service.establish(db))
            local workspace = assert(uuid.v4())
            local created = service.execute(db,"docker-requester","request",{workspace_id = workspace,idempotency_key = "environment",request_kind = "permission",policy = "phase3-docker",proposal = {kind = "operation",ref = "bee.placement.docker.binding:prepare_environment",revision = "1",input_digest = string.rep("a",64),payload = {network = "network",endpoint = "endpoint",listener = "listener",profile = "profile"}},prompt = {text = "Persistent network admission"}},nil,nil)
            assert(created.ok,tostring(created.message))
            local view = assert(bounds.object(created.value))
            local decided = service.execute(db,"docker-person","decide",{approval_id = view.approval_id,expected_revision = view.revision,proposal_digest = view.proposal_digest,reviewed_digest = view.reviewed_digest,decision = "approved"},nil,nil)
            assert(decided.ok,tostring(decided.message))
            local record = assert(grants.read(db,tostring(view.approval_id) .. ":grant"))
            test.eq(record.domain,"docker_environment"); test.eq(record.terms.kind,"until_revoked")
            test.eq(record.provenance.kind,"decision")
            test.eq(#assert(db:query("SELECT * FROM bee_approval_grants WHERE approval_id = ?",{view.approval_id})),1)
            local revoked = service.execute(db,"docker-person","grant",{operation = "revoke",grant_id = record.grant_id,expected_revision = record.revision},nil,nil)
            assert(revoked.ok,tostring(revoked.message))
            test.eq(service.execute(db,"docker-requester","grant",{operation = "check",grant_id = record.grant_id,subject = record.subject,scope = record.scope},nil,nil).ok,false)
            db:release()
        end)
        test.it("imports approved and revoked legacy receipts without changing their exact selection or inventing a consenting actor",function()
            local node = "node"
            local receipt = {state = "approved",approval_id = "old",selection_digest = string.rep("a",64),proposal_digest = string.rep("b",64),owner_incarnation = 1,address = "bridge"}
            local record = assert(legacy.build(node,receipt,nil,"network"))
            test.eq(record.provenance.kind,"legacy"); test.eq(record.provenance.consenting_actor,"unrecorded")
            test.eq(record.subject.principal_id,node)
            test.eq(assert(bounds.object(record.scope.parameters)).selection_digest,receipt.selection_digest)
            receipt.state = "revoked"
            test.eq(assert(legacy.build(node,receipt,nil,"network")).state,"revoked")
            local original = {owner_node = "original-node",workspace_id = "workspace",requester_id = "requester",decider_id = "person",decided_at = clock.now(),proposal = {payload = {network = "original-network"}}}
            local attributed = assert(legacy.build(node,receipt,original,"different-network"))
            test.eq(attributed.subject.principal_id,"original-node")
            test.eq(attributed.metadata.network,"original-network")
            test.eq(attributed.granted_by,"person")
            local db = schema.open("bee.approvals:test_db","bee.approvals.migrations")
            local tx = assert(db:begin())
            local original_grant: grants.Grant = {grant_id = "old:grant",domain = "decision",owner_node = "original-node",workspace_id = "workspace",requester_id = "requester",granted_by = "person",subject = {},scope = {},terms = {kind = "once"},provenance = {kind = "legacy"},metadata = {},state = "exhausted",revision = 1,used = 1,reserved = 0,created_at = clock.now()}
            assert(not grants.create(tx,original_grant))
            local imported = assert(legacy.import(tx,node,receipt,original,"different-network"))
            test.eq(imported.grant_id,original_grant.grant_id)
            test.eq(imported.state,"revoked")
            test.eq(imported.revision,2)
            local history = assert(tx:query("SELECT kind FROM bee_approval_grant_history WHERE grant_id = ? ORDER BY revision",{imported.grant_id}))
            test.eq(#history,2); test.eq(history[2].kind,"grant.migrated")
            test.eq(#assert(tx:query("SELECT * FROM bee_approval_grants WHERE grant_id = ?",{imported.grant_id})),1)
            test.eq(assert(legacy.import(tx,node,receipt,original,"different-network")).revision,2)
            assert(tx:commit()); db:release()
        end)
        local function port(decision: string)
            local effects: {string} = {}
            local receipt: environment.Receipt? = nil
            local io: environment.IO = {
                load = function() return receipt, nil end,
                save = function(value) receipt = value; effects[#effects + 1] = "record"; return nil end,
                request = function(_selected: environment.Selection): (environment.Approval?, string?) effects[#effects + 1] = "request"; return {approval_id = "approval", proposal_digest = string.rep("a", 64), owner_incarnation = 1}, nil end,
                await = function(_approval: environment.Approval): (string?, string?) return decision, nil end,
                check = function(_receipt: environment.Receipt,_selected: environment.Selection): string? effects[#effects + 1] = "check"; return nil end,
                consume = function(_approval: environment.Approval): string? effects[#effects + 1] = "consume"; return nil end,
                provision = function(_selected: environment.Selection): (string?, string?) effects[#effects + 1] = "provision"; return "172.29.0.1:0", nil end,
                activate = function(_receipt: environment.Receipt): string? effects[#effects + 1] = "activate"; return nil end,
                progress = function(_text: string) end,
            }
            return io, effects
        end
        local selection: environment.Selection = {workspace = "workspace", profile = "profile", digest = string.rep("b", 64), network = "bee-coding", policy = "docker-environment"}
        test.it("asks once, consumes before provisioning, records and reuses the approved environment", function()
            local io, effects = port("approved")
            local receipt, reason = environment.prepare(io, selection)
            test.is_nil(reason); test.eq(receipt and receipt.state, "approved")
            test.eq(table.concat(effects, ","), "request,record,consume,check,provision,record,activate")
            local again = environment.prepare(io, selection)
            test.eq(again and again.approval_id, "approval")
            test.eq(table.concat(effects, ","), "request,record,consume,check,provision,record,activate,check,provision,record,activate")
        end)
        test.it("refuses future provisioning after common grant revocation without undoing the completed receipt", function()
            local io, effects = port("approved")
            local completed = assert(environment.prepare(io,selection))
            local before = table.concat(effects,",")
            io.check = function(_receipt: environment.Receipt,_selected: environment.Selection): string? return "grant was revoked" end
            local next_receipt, err = environment.prepare(io,selection)
            test.eq(next_receipt,nil)
            test.eq(err,"grant was revoked")
            test.eq(completed.state,"approved")
            test.eq(table.concat(effects,","),before)
        end)
        test.it("records a person's decline without creating a network or listener", function()
            local io, effects = port("denied")
            local receipt, reason = environment.prepare(io, selection)
            test.is_nil(receipt); test.is_true(reason and reason:find("declined", 1, true) ~= nil)
            test.eq(table.concat(effects, ","), "request,record,record")
            environment.prepare(io, selection)
            test.eq(table.concat(effects, ","), "request,record,record")
        end)
        test.it("refuses a revoked receipt and an approval bound to another profile digest", function()
            local io, effects = port("approved")
            environment.prepare(io, selection)
            io.check = function(_receipt: environment.Receipt,_selected: environment.Selection): string? return "grant was revoked" end
            io.save({state = "revoked", approval_id = "approval", proposal_digest = string.rep("a",64), owner_incarnation = 1, selection_digest = selection.digest})
            local receipt, reason = environment.prepare(io, selection)
            test.is_nil(receipt); test.is_true(reason and reason:find("revoked",1,true) ~= nil)
            local changed: environment.Selection = {workspace = selection.workspace, profile = selection.profile, digest = string.rep("c",64), network = selection.network, policy = selection.policy}
            local other, failure = environment.prepare(io, changed)
            test.is_nil(other); test.is_true(failure and failure:find("changed",1,true) ~= nil)
        end)
        test.it("reports expiry separately from a person's decline", function()
            local io, effects = port("expired")
            local receipt, reason = environment.prepare(io, selection)
            test.is_nil(receipt); test.is_true(reason and reason:find("expired",1,true) ~= nil)
            test.is_true(reason and reason:find("declined",1,true) == nil)
            test.eq(table.concat(effects, ","), "request,record")
        end)
        test.it("does not provision when approval consumption fails", function()
            local io, effects = port("approved")
            io.consume = function(_approval: environment.Approval): string? return "approval is no longer valid" end
            local receipt, reason = environment.prepare(io, selection)
            test.is_nil(receipt); test.eq(reason, "approval is no longer valid")
            test.eq(table.concat(effects, ","), "request,record")
        end)
    end)
end
return test.run_cases(M.run)
