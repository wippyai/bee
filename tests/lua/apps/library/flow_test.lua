-- MIT. The Library's pointer actions and package flow over a recorded
-- confirmation owner and a recorded Hub read queue: the list's refresh hit
-- reloads the tab, and confirming a Hub change accepts the displayed target
-- with the gesture the person confirmed with before the apply starts.
local test = require("test")
local channel = require("channel")
local confirmation = require("confirmation")
local caller = require("caller")
local model = require("model")
local hub = require("hub")
local contents = require("contents")
local session = require("session")
local reads = require("reads")
local delivery_actions = require("delivery_actions")
local package_flow = require("package_flow")
local hits = require("hits")

type Object = {[string]: unknown}
type Recorded = {methods: {string}, gestures: {unknown}}
type Queue = {reads: integer, applies: {hub.Intent}}
type Ask = (string, Object) -> caller.Envelope?

local DIGEST = string.rep("a", 64)

-- owner answers the confirmation calls the way the approvals owner does for
-- one pending confirmation that the person approves.
local function owner(recorded: Recorded): Ask
    return function(method: string, request: Object): caller.Envelope?
        recorded.methods[#recorded.methods + 1] = method
        if method == "bee.approvals.binding:request" then
            return {ok = true, error = nil, value = {state = "pending", approval_id = "approval-1", revision = 1,
                proposal_digest = DIGEST, reviewed_digest = DIGEST}}
        end
        if method == "bee.approvals.binding:decide" then
            local assurance = request.assurance :: Object
            recorded.gestures[#recorded.gestures + 1] = assurance.gesture
            return {ok = true, error = nil, value = {state = "decided", decision = "approved", approval_id = "approval-1",
                proposal_digest = DIGEST, reviewed_digest = DIGEST, owner_incarnation = "owner-1"}}
        end
        if method == "bee.approvals.binding:effect" then return {ok = true, error = nil, value = {state = "claimed"}} end
        return {ok = true, error = nil, value = {}}
    end
end

local function context(recorded: Recorded): session.Session
    local state = model.new("workspace-1")
    local review = confirmation.new({workspace_id = "workspace-1", origin = {app_id = "bee.apps.library.app:app", instance_id = "library"}},
        owner(recorded))
    local updates: channel.Channel<boolean> = channel.new(1)
    return {state = state, hubs = state.hub, gov = state.governed,
        ui = {offset = 0, status = "", reading = false, editor = nil, content = contents.new()}, review = review, launch = nil,
        updates = updates, pending = {}, reads = {}, reading = nil, generation = 0, running = true, dirty = false, busy = false,
        apply_pending = false, gesture = "enter", effect_gesture = "enter", visible_rows = 1}
end

local function queue(recorded: Queue): reads.Reads
    return {fold_read = function(_: string, _: session.Reply) end, start_next = function() end,
        begin = function(_: {hub.Intent}): boolean recorded.reads = recorded.reads + 1; return true end,
        begin_apply = function(intent: hub.Intent): boolean recorded.applies[#recorded.applies + 1] = intent; return true end}
end

local function define_tests()
    test.describe("Library flow", function()
        test.it("reloads the shown tab on the list's refresh hit", function()
            local ctx = context({methods = {}, gestures = {}})
            local base = session.new(ctx)
            local actions = delivery_actions.new(ctx.state, ctx.review, base.wake,
                {running = function(): boolean return true end, gesture = function(): "enter" return "enter" end})
            local recorded: Queue = {reads = 0, applies = {}}
            local feed = queue(recorded)
            local flow = package_flow.new(ctx, base, actions, feed)
            local loads = 0
            flow.load_tab = function() loads = loads + 1 end
            local pointer = hits.new(ctx, base, actions, feed, flow)
            pointer.list_hit("refresh", "")
            test.eq(loads, 1)
        end)

        test.it("accepts a Hub change with the person's gesture before starting the apply", function()
            local recorded: Recorded = {methods = {}, gestures = {}}
            local ctx = context(recorded)
            local base = session.new(ctx)
            local actions = delivery_actions.new(ctx.state, ctx.review, base.wake,
                {running = function(): boolean return true end, gesture = function(): "enter" return "enter" end})
            local applies: Queue = {reads = 0, applies = {}}
            local flow = package_flow.new(ctx, base, actions, queue(applies))
            ctx.hubs.selected_operation = {digest = DIGEST, component = "acme.notes", action = "install", state = "prepared",
                message = "", baseline_revision = 1, request = {component = "acme.notes"}, migration_work = {}}
            test.is_nil(hub.recover(ctx.hubs))
            test.is_true(flow.open_hub_confirmation())
            ctx.gesture = "click"
            flow.confirm()
            test.eq(#recorded.gestures, 1)
            test.eq(recorded.gestures[1], "click")
            test.is_true(ctx.apply_pending)
            test.eq(#applies.applies, 1)
            test.eq(applies.applies[1].expected_digest, DIGEST)
        end)
    end)
end

return test.run_cases(define_tests)
