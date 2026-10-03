-- MIT. The inbox lease slice: the spec grammar, the governance operations a
-- lease needs, the marked batch and the lease rows, all pure.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local appearance = require("appearance")
local model = require("model")
local leases = require("leases")
local lease_form = require("lease_form")
local forms = require("forms")
local view = require("view")
type Object = {[string]: unknown}

local function approval(id: string, state: string, ref: string, payload: Object, extra: Object?): model.ApprovalView
    local item: Object = {approval_id = id, workspace_id = "ws-1", requester_id = "bee.gov.activation", request_kind = "permission",
        policy = "inbox-test", proposal = {kind = "operation", ref = ref, revision = "r1", payload = payload},
        proposal_digest = string.rep("a", 64), prompt = {text = "Apply notes?"}, revision = 1, state = state,
        owner_node = "node-1", owner_incarnation = 3, expires_at = "2026-09-09T10:00:00.000Z",
        created_at = "2026-09-09T09:0" .. tostring(#id % 10) .. ":00.000Z"}
    for key, value in pairs(extra or {}) do item[key] = value end
    return assert(model.decode_view(item))
end
local ACTIVATION = {workspace_id = "ws-1", source_node = "node-src", source_workspace = "notes"}
local function rows_of(views: {model.ApprovalView}): {[string]: model.Row}
    local rows: {[string]: model.Row} = {}
    for index, item in ipairs(views) do rows[item.approval_id] = model.summary(item, index) end
    return rows
end

local function define_tests()
    test.describe("Inbox lease spec", function()
        test.it("builds a bounded spec from form values", function()
            local spec = assert(leases.spec("7200", "5", {{capability = "workspace.files.write", parameters = "subpath=docs"},
                {capability = "contract.call", parameters = "binding=a:b,methods=get|put"}, {capability = "", parameters = ""}}))
            test.eq(spec.ttl_seconds, 7200)
            test.eq(spec.max_applies, 5)
            test.eq(#spec.extras, 2)
            test.eq((assert(bounds.object(spec.extras[2].parameters))).methods, "get|put")
            test.eq(assert(leases.spec("none", "3", {})).ttl_seconds, nil)
        end)
        test.it("refuses an unbounded, out-of-range or malformed spec", function()
            test.is_nil((leases.spec("none", "", {})))
            test.is_nil((leases.spec("999999999", "", {})))
            test.is_nil((leases.spec("3600", "0", {})))
            test.is_nil((leases.spec("3600", "", {{capability = "Bad Cap", parameters = "a=b"}})))
            test.is_nil((leases.spec("3600", "", {{capability = "workspace.files.write", parameters = "nonsense"}})))
        end)
        test.it("takes a capability with no parameters", function()
            local spec = assert(leases.spec("3600", "", {{capability = "hive.view", parameters = ""}}))
            test.eq(spec.extras[1].capability, "hive.view")
            test.eq(next(spec.extras[1].parameters), nil)
        end)
    end)
    test.describe("Inbox lease form", function()
        local function pending(): model.ApprovalView
            return approval("r1", "pending", leases.ACTIVATION, ACTIVATION)
        end
        local function type_into(state: lease_form.State, text: string)
            for char in text:gmatch(".") do
                forms.key(state.form, {type = "key", action = "press", key = char, key_type = "runes"})
            end
        end
        test.it("submits the default expiry once a use limit or expiry is chosen", function()
            local state = lease_form.new(pending())
            local spec = assert(lease_form.submit(state))
            test.eq(spec.ttl_seconds, 86400)
            test.eq(#spec.extras, 0)
        end)
        test.it("refuses no expiry without a use limit and marks the field", function()
            local state = lease_form.new(pending())
            forms.select_set(assert(state.form.fields[1].select), "none")
            test.is_nil((lease_form.submit(state)))
            test.is_true(state.form.fields[2].error ~= nil)
            test.is_false(forms.can_submit(state.form))
        end)
        test.it("validates extras as a capability with optional parameters", function()
            local state = lease_form.new(pending())
            forms.focus_at(state.form, 3)
            type_into(state, "hive.view")
            local bare = assert(lease_form.submit(state))
            test.eq(bare.extras[1].capability, "hive.view")
            forms.focus_at(state.form, 4)
            type_into(state, "nonsense")
            test.is_nil((lease_form.submit(state)))
            test.is_true(state.form.fields[4].error ~= nil)
        end)
        test.it("draws inside every size and offers submit only when valid", function()
            local state = lease_form.new(pending())
            for _, size in ipairs({{100, 30}, {60, 24}, {40, 14}}) do
                local drawn = lease_form.draw(size[1], size[2], appearance.defaults(), state)
                test.eq(#drawn.rows, size[2])
                local text = table.concat(drawn.rows, "\n"):gsub("\27%[[0-9;]*m", "")
                test.is_true(text:find("LEASE REQUEST", 1, true) ~= nil)
            end
            local drawn = lease_form.draw(100, 30, appearance.defaults(), state)
            local submit = false
            for _, hit in ipairs(drawn.hits) do if hit.kind == "submit" then submit = true end end
            test.is_true(submit)
            test.eq(lease_form.input(state, {type = "key", action = "press", key_type = "escape"}, drawn), "cancel")
            test.eq(lease_form.input(state, {type = "key", action = "press", key = "s", key_type = "runes", ctrl = true}, drawn), "submit")
        end)
    end)
    test.describe("Inbox lease operations", function()
        test.it("proposes a lease only from an open pending activation request", function()
            local spec = assert(leases.spec("3600", "", {}))
            local pending = approval("r1", "pending", leases.ACTIVATION, ACTIVATION)
            local intent = assert(leases.propose_intent(pending, spec, "key-1"))
            test.eq(intent.target, "bee.gov.binding:destination_call")
            test.eq(intent.request.operation, "lease_propose")
            test.eq(intent.request.source_workspace, "notes")
            local decided = approval("r2", "decided", leases.ACTIVATION, ACTIVATION, {decision = "approved", decider_id = "bee.test.alice"})
            test.is_nil((leases.propose_intent(decided, spec, "key-2")))
            test.is_nil((leases.propose_intent(approval("r3", "pending", "bee.other:op", ACTIVATION), spec, "key-3")))
        end)
        test.it("grants only an approved lease request", function()
            local approved = approval("g1", "decided", leases.PROPOSAL, ACTIVATION, {decision = "approved", decider_id = "bee.test.alice"})
            local intent = assert(leases.grant_intent(approved, "key-1"))
            test.eq(intent.request.operation, "lease_grant")
            test.eq(intent.request.approval_id, "g1")
            local denied = approval("g2", "decided", leases.PROPOSAL, ACTIVATION, {decision = "denied", decider_id = "bee.test.alice"})
            test.is_nil((leases.grant_intent(denied, "key-2")))
            test.is_nil((leases.grant_intent(approval("g3", "pending", leases.PROPOSAL, ACTIVATION), "key-3")))
        end)
        test.it("lists active leases with usage and revokes the selected one at its revision", function()
            local slice = leases.new()
            local raw = {ok = true, value = {leases = {
                {lease_id = "l-1", target = "bee.gov:notes", state = "active", applies_used = 2, max_applies = 5, revision = 3,
                    granted_by = "bee.test.alice", uses = {{intent_id = "i-1"}}, envelope = {{capability = "workspace.files.write", scope = {subpath = "docs"}}},
                    expires_at = "2026-09-10T00:00:00.000Z"},
                {lease_id = "l-2", target = "bee.gov:notes", state = "revoked", applies_used = 1, revision = 2, granted_by = "bee.test.alice", uses = {},
                    envelope = {}}}}}
            test.is_nil(leases.apply_list(slice, "ws-1", "ws-1", raw))
            local rows = leases.rows(slice)
            test.eq(#rows, 2)
            test.eq(rows[1].lease_id, "l-1")
            test.eq(rows[1].uses, 1)
            test.is_nil((leases.revoke_intent(slice, "k")))
            leases.select(slice, rows[1])
            local intent = assert(leases.revoke_intent(slice, "k"))
            test.eq(intent.request.operation, "lease_revoke")
            test.eq(intent.request.expected_revision, 3)
            leases.select(slice, rows[2])
            test.is_nil((leases.revoke_intent(slice, "k")))
            test.is_true(leases.apply_list(slice, "ws-1", "ws-1", {ok = false, error = {code = "DENIED", message = "no"}}) ~= nil)
        end)
        test.it("words each outcome and a governance refusal", function()
            test.is_true(leases.notice("lease_grant", {ok = true}):find("granted", 1, true) ~= nil)
            test.is_true(leases.notice("lease_grant", {ok = false, error = {code = "DENIED", message = "outside"}}):find("DENIED", 1, true) ~= nil)
        end)
    end)
    test.describe("Inbox batch", function()
        test.it("marks pending requests of one requester and decides them in one intent", function()
            local one = approval("b1", "pending", "bee.x:op", {})
            local two = approval("b2", "pending", "bee.x:op", {})
            local other = approval("b3", "pending", "bee.x:op", {}, {requester_id = "bee.other"})
            local done = approval("b4", "decided", "bee.x:op", {}, {decision = "approved", decider_id = "bee.test.alice"})
            local rows = rows_of({one, two, other, done})
            local slice = leases.new()
            test.is_nil(leases.toggle_mark(slice, rows, "b1"))
            test.is_nil(leases.toggle_mark(slice, rows, "b2"))
            test.is_true(leases.toggle_mark(slice, rows, "b3") ~= nil)
            test.is_true(leases.toggle_mark(slice, rows, "b4") ~= nil)
            local intent = assert(leases.batch_intent(slice, rows, "approved"))
            test.eq(intent.target, "bee.approvals.binding:decide_batch")
            local decisions = principals.objects(intent.request.decisions)
            test.eq(#decisions, 2)
            test.eq(decisions[1].expected_revision, 1)
            test.eq(decisions[1].proposal_digest, string.rep("a", 64))
            test.is_nil((leases.batch_intent(slice, rows, "maybe")))
            test.is_nil(leases.toggle_mark(slice, rows, "b1"))
            test.eq(#leases.marked(slice, rows), 1)
        end)
        test.it("folds committed views and clears the marks, or keeps them on a refusal", function()
            local one = approval("b1", "pending", "bee.x:op", {})
            local rows = rows_of({one})
            local slice = leases.new()
            leases.toggle_mark(slice, rows, "b1")
            local decided = approval("b1", "decided", "bee.x:op", {}, {decision = "approved", decider_id = "bee.test.alice", revision = 2})
            local folded = 0
            local refused = leases.apply_batch(slice, {kind = "failure", code = "CONFLICT", message = "stale", replayed = false}, function(_view: model.ApprovalView) folded = folded + 1 end)
            test.is_true(refused:find("CONFLICT", 1, true) ~= nil)
            test.eq(#leases.marked(slice, rows), 1)
            local notice = leases.apply_batch(slice, {kind = "success", value = {decisions = {decided}}, replayed = false}, function(_view: model.ApprovalView) folded = folded + 1 end)
            test.eq(folded, 1)
            test.eq(notice, "Decided 1 requests")
            test.eq(#leases.marked(slice, rows), 0)
        end)
    end)
    test.describe("Inbox lease approval screen", function()
        test.it("states the lease terms from typed values, apart from the request's own expiry", function()
            local granting = approval("g1", "pending", leases.PROPOSAL, {target = "bee.gov:notes", ttl_seconds = 2592000, max_applies = 3,
                resolved_capabilities = {"Write docs"}, permission_changes = {"ignored free text"}})
            local text = table.concat(model.permission_lines(granting), "\n")
            test.is_true(text:find("Lease for: bee.gov:notes", 1, true) ~= nil)
            test.is_true(text:find("30 days from the moment it is granted", 1, true) ~= nil)
            test.is_true(text:find("Max applies: 3", 1, true) ~= nil)
            test.is_true(text:find("Capability: Write docs", 1, true) ~= nil)
            test.is_nil((text:find("ignored free text", 1, true)))
            local open = model.permission_lines(approval("g2", "pending", leases.PROPOSAL, {target = "bee.gov:notes", resolved_capabilities = {"Write docs"}}))
            test.is_true(table.concat(open, "\n"):find("Lasts: no expiry", 1, true) ~= nil)
        end)
    end)
    test.describe("Inbox lease frame", function()
        test.it("keeps every active lease listable beyond sixty-four rows", function()
            local slice = leases.new()
            local listed: {Object} = {}
            for index = 1, 200 do
                listed[index] = {lease_id = "l-" .. tostring(index), target = "bee.gov:notes", state = "active", applies_used = 0,
                    revision = 1, granted_by = "p", uses = {}, envelope = {}, max_applies = 1}
            end
            test.is_nil(leases.apply_list(slice, "ws-1", "ws-1", {ok = true, value = {leases = listed}}))
            test.eq(#leases.rows(slice), 200)
        end)
        test.it("shows every term and grant of a long ceiling at a small size and approves only after the end", function()
            local caps: {string} = {}
            for index = 1, 16 do caps[index] = "Write workspace files under directory-number-" .. tostring(index) .. " " .. string.rep("long ", 30) end
            local granting = approval("g9", "pending", leases.PROPOSAL, {target = "bee.gov:notes", ttl_seconds = 3600, max_applies = 3, resolved_capabilities = caps})
            local state = model.new({"ws-1"})
            model.apply_inbox(state, "ws-1", assert(model.decode_reply({ok = true, error = nil, value = {changes = {{seq = 1, approval_id = "g9", revision = 1, request = granting}},
                next_seq = 1, more = false}, replayed = false})))
            model.select(state, "g9")
            model.apply_read(state, "g9", assert(model.decode_reply({ok = true, error = nil, value = granting, replayed = false})))
            local slice = leases.new()
            local seen = ""
            local function page(): {string}
                local drawn = view.draw(60, 12, appearance.defaults(), state, model.rows(state), 0, "", slice)
                local plain = table.concat(drawn.rows, "\n"):gsub("\27%[[0-9;]*m", "")
                seen = seen .. plain
                return drawn.rows
            end
            page()
            test.is_false(slice.review_complete)
            local approve_enabled = false
            for _ = 1, 200 do
                leases.review_scroll(slice, 1)
                page()
            end
            test.is_true(slice.review_complete)
            for index = 1, 16 do
                test.is_true(seen:find("directory-number-" .. tostring(index) .. " ", 1, true) ~= nil)
            end
            test.is_true(seen:find("Lasts: 1 hours", 1, true) ~= nil)
            test.is_true(seen:find("Max applies: 3", 1, true) ~= nil)
            local last = view.draw(60, 12, appearance.defaults(), state, model.rows(state), 0, "", slice)
            for _, hit in ipairs(last.hits) do if hit.kind == "approve" then approve_enabled = true end end
            test.is_true(approve_enabled)
            local fresh = leases.new()
            local top = view.draw(60, 12, appearance.defaults(), state, model.rows(state), 0, "", fresh)
            for _, hit in ipairs(top.hits) do test.is_true(hit.kind ~= "approve") end
        end)
        test.it("renders a capability description far past 512 bytes without truncation", function()
            local members: {string} = {}
            for index = 1, 120 do members[index] = "Get" .. string.format("%03d", index) end
            local long = "Call app binding a:b using " .. table.concat(members, ", ")
            test.is_true(#long > 900)
            local granting = approval("g7", "pending", leases.PROPOSAL, {target = "bee.gov:notes", ttl_seconds = 60, resolved_capabilities = {long}})
            local joined = table.concat(leases.review_lines(granting, 60), ""):gsub("%s+", "")
            test.is_true(joined:find("Get120", 1, true) ~= nil)
            test.is_true(joined:find("Get001", 1, true) ~= nil)
        end)
        test.it("enables Revoke for an exhausted lease that holds a reservation", function()
            local state = model.new({"ws-1"})
            local slice = leases.new()
            leases.apply_list(slice, "ws-1", "ws-1", {ok = true, value = {leases = {{lease_id = "l-1", target = "t", state = "exhausted", applies_used = 1,
                revision = 2, granted_by = "p", envelope = {}, max_applies = 1, uses = {{intent_id = "i", state = "reserved"}}}}}})
            leases.show_leases(slice, true)
            leases.select(slice, leases.rows(slice)[1])
            local drawn = view.draw(100, 20, appearance.defaults(), state, model.rows(state), 0, "", slice)
            local revoke = false
            for _, hit in ipairs(drawn.hits) do if hit.kind == "revoke" then revoke = true end end
            test.is_true(revoke)
        end)
        test.it("keeps lease requests out of a batch", function()
            local granting = approval("g8", "pending", leases.PROPOSAL, {target = "t"})
            local rows = rows_of({granting})
            test.is_true(leases.toggle_mark(leases.new(), rows, "g8") ~= nil)
        end)
        test.it("revokes an exhausted lease that still has a reservation", function()
            local slice = leases.new()
            leases.apply_list(slice, "ws-1", "ws-1", {ok = true, value = {leases = {{lease_id = "l-1", target = "t", state = "exhausted", applies_used = 1,
                revision = 2, granted_by = "p", envelope = {}, max_applies = 1, uses = {{intent_id = "i", state = "reserved"}}},
                {lease_id = "l-2", target = "t", state = "exhausted", applies_used = 1, revision = 2, granted_by = "p", envelope = {}, max_applies = 1,
                    uses = {{intent_id = "j", state = "admitted"}}}}}})
            local rows = leases.rows(slice)
            leases.select(slice, rows[1])
            test.is_true(leases.revoke_intent(slice, "k") ~= nil)
            leases.select(slice, rows[2])
            test.is_nil((leases.revoke_intent(slice, "k")))
        end)
        test.it("gives the lease action and the lease rows different hit kinds", function()
            local state = model.new({"ws-1"})
            local pending = approval("r1", "pending", leases.ACTIVATION, ACTIVATION)
            model.apply_inbox(state, "ws-1", assert(model.decode_reply({ok = true, error = nil, value = {changes = {{seq = 1, approval_id = "r1", revision = 1, request = pending}},
                next_seq = 1, more = false}, replayed = false})))
            model.select(state, "r1")
            model.apply_read(state, "r1", assert(model.decode_reply({ok = true, error = nil, value = pending, replayed = false})))
            local slice = leases.new()
            local drawn = view.draw(140, 30, appearance.defaults(), state, model.rows(state), 0, "", slice)
            local action = false
            for _, button in ipairs(assert(drawn.controls).buttons) do
                if button.kind == "lease" and button.more then action = true end
            end
            test.is_true(action)
            state.technical = true
            local technical = view.draw(140, 30, appearance.defaults(), state, model.rows(state), 0, "", slice)
            local lease_key: string? = nil
            for _, button in ipairs(assert(technical.controls).buttons) do if button.kind == "lease" then lease_key = button.key end end
            test.eq(lease_key, "E")
            leases.apply_list(slice, "ws-1", "ws-1", {ok = true, value = {leases = {{lease_id = "l-1", target = "t", state = "active", applies_used = 0,
                revision = 1, granted_by = "p", uses = {}, envelope = {}, max_applies = 1}}}})
            leases.show_leases(slice, true)
            local listed = view.draw(140, 30, appearance.defaults(), state, model.rows(state), 0, "", slice)
            local rows = 0
            for _, hit in ipairs(listed.hits) do
                test.is_true(hit.kind ~= "lease")
                if hit.kind == "lease_row" then rows = rows + 1 end
            end
            test.eq(rows, 1)
        end)
        test.it("shows active leases with usage and the revoke action", function()
            local state = model.new({"ws-1"})
            local slice = leases.new()
            leases.apply_list(slice, "ws-1", "ws-1", {ok = true, value = {leases = {{lease_id = "l-1", target = "bee.gov:notes", state = "active",
                applies_used = 2, max_applies = 5, revision = 3, granted_by = "bee.test.alice", uses = {}, envelope = {}}}}})
            leases.show_leases(slice, true)
            leases.select(slice, leases.rows(slice)[1])
            local frame = view.draw(100, 20, appearance.defaults(), state, model.rows(state), 0, "", slice)
            local text = table.concat(frame.rows, "\n"):gsub("\27%[[0-9;]*m", "")
            test.is_true(text:find("LEASES", 1, true) ~= nil)
            test.is_true(text:find("used 2/5", 1, true) ~= nil)
            test.is_true(text:find("Revoke", 1, true) ~= nil)
        end)
        test.it("marks batched requests in the list", function()
            local state = model.new({"ws-1"})
            local one = approval("b1", "pending", "bee.x:op", {})
            model.apply_inbox(state, "ws-1", assert(model.decode_reply({ok = true, error = nil, value = {changes = {{seq = 1, approval_id = "b1", revision = 1, request = one}},
                next_seq = 1, more = false}, replayed = false})))
            local slice = leases.new()
            leases.toggle_mark(slice, state.rows, "b1")
            local frame = view.draw(100, 20, appearance.defaults(), state, model.rows(state), 0, "", slice)
            test.is_true(table.concat(frame.rows, "\n"):gsub("\27%[[0-9;]*m", ""):find("[x]", 1, true) ~= nil)
        end)
    end)
end
return test.run_cases(define_tests)
