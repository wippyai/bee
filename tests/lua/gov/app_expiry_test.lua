-- MIT. An install the person never answered, or denied, ends: the agent
-- delivers, the approval expires in Needs you, the activation worker settles
-- the install as expired and the Library offers the version in Shared again.
-- Installing again from the Library asks anew; the person denies it; the agent
-- requests delivery again, the person approves and the application installs,
-- and the person shares it with the hive from the Library.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local bounds = require("bounds")
local json = require("json")
local time = require("time")
local uuid = require("uuid")
local harness = require("harness")
local guide = require("guide")
local governed = require("governed")
local library = require("library")
local principals = require("principals")

local OVERLAY = "expiryapp"
local NAMESPACE = "app." .. OVERLAY
local MENU = "bee.tests.gov:unplaced_menu"
local POLICY = "workspace-application-delivery"
local TTL_MS = 1500
type Object = {[string]: unknown}

local function version(): {Object}
    local entries: {Object} = {}
    for _, entry in ipairs(guide.example()) do entries[#entries + 1] = entry end
    local renamed = assert(json.encode(entries)):gsub(guide.NAMESPACE:gsub("%p", "%%%0"), NAMESPACE)
        :gsub("bee%.shell:apps_menu", MENU)
    return assert(json.decode(renamed)) :: {Object}
end

-- The host's approval window for workspace applications, shortened so the
-- suite sees one expire; restoring it is idempotent.
local function short_window(): () -> ()
    local function window(ttl: integer?): integer?
        local entry = assert(registry.get("bee.security.approvals:approver_policies"))
        local data = assert(bounds.object(entry.data))
        local before: integer? = nil
        for _, raw in ipairs(principals.objects(data.policies)) do
            if raw.name == POLICY then
                before = math.floor(assert(tonumber(raw.max_ttl_ms)))
                if ttl then raw.max_ttl_ms = ttl end
            end
        end
        local changes = registry.snapshot():changes()
        changes:update(entry)
        assert(changes:apply())
        return before
    end
    local original = assert(window(TTL_MS))
    local restored = false
    return function()
        if not restored then window(original); restored = true end
    end
end

-- The approval owner's reconcile expires what passed its deadline.
local function reconcile()
    local owner = funcs.new():with_actor(security.new_actor("bee.approvals.outbox"))
        :with_scope(security.new_scope({assert(security.policy("bee.security.approvals:approval_owner_policy"))}))
    harness.value(harness.reply(owner:call("bee.approvals.binding:reconcile", {})))
end

-- What the Library shows the person for this workspace.
local function shown(workspace: string): library.State
    local state = library.new(workspace)
    local plans = harness.value(harness.library(workspace, {operation = "list"}))
    test.is_true(governed.apply_list(state.governed, governed.reply({ok = true, replayed = false, value = plans})))
    local available = harness.value(harness.library(workspace, {operation = "available"}))
    test.is_true(governed.apply_available(state.governed, governed.reply({ok = true, replayed = false, value = available})))
    local activations = harness.value(harness.library(workspace, {operation = "activations"}))
    test.is_true(governed.apply_activations(state.governed, governed.reply({ok = true, replayed = false, value = activations})))
    return state
end

local function row_of(state: library.State, tab: string): library.Row?
    for _, row in ipairs(library.rows(state, tab)) do
        if row.app == OVERLAY then return row end
    end
    return nil
end

local function define_tests()
    test.describe("an install that ends without approval", function()
        test.it("returns to Shared when its approval expires or is denied and installs when asked again", function()
            local restore = short_window()
            local done, failure = pcall(function()
                local workspace = harness.isolated("expiry")
                local writer = harness.author(workspace, "expiry")
                local before = harness.running()
                -- Other suites' applications may already be installed in this workspace.
                local held = library.summary(shown(workspace))

                local digest = harness.freeze(writer, OVERLAY, version(), "1.0.0")
                local first = harness.value(harness.request(writer, OVERLAY, workspace, "1.0.0", digest))
                test.eq(first.activation_phase, "approval_bound")
                time.sleep(tostring(TTL_MS + 500) .. "ms")
                reconcile()
                -- Later requests get the host's own window, long enough to be answered and applied.
                restore()
                harness.drain()
                harness.close_presented(before)

                local expired = shown(workspace)
                test.is_nil(row_of(expired, "installed"))
                local shared = assert(row_of(expired, "shared"))
                test.eq(shared.status, "Shared")
                test.eq(shared.note, "Approval expired — install again")
                -- The expired install is not counted as installed.
                test.eq(library.summary(expired):match("^%d+ installed"), held:match("^%d+ installed"))

                -- Install again from the Library raises a fresh approval; the person denies it.
                local ended = expired.governed.activations[1]
                test.eq(ended.outcome, "expired")
                local intent_id = "library-" .. assert(uuid.v7())
                local asked = harness.value(harness.library(workspace, {operation = "prepare",
                    source_node = ended.source_node, source_workspace = ended.source_workspace, version = "1.0.0",
                    intent_id = intent_id, receipt_key = intent_id}))
                test.eq(asked.phase, "approval_bound")
                test.is_false(asked.approval_id == first.approval_id)
                harness.answer(workspace, asked.approval_id, "denied")
                harness.drain()
                harness.close_presented(before)
                local denied = shown(workspace)
                test.is_nil(row_of(denied, "installed"))
                test.eq(assert(row_of(denied, "shared")).note, "Denied")

                -- The agent requests delivery again: a fresh approval, approved and installed.
                local again = harness.value(harness.request(writer, OVERLAY, workspace, "1.0.0", digest))
                test.eq(again.activation_phase, "approval_bound")
                test.is_false(again.approval_id == first.approval_id or again.approval_id == asked.approval_id)
                test.eq(harness.settle(writer, OVERLAY, workspace, again, "1.0.0").outcome, "applied")
                harness.close_presented(before)
                local installed = shown(workspace)
                local row = assert(row_of(installed, "installed"))
                test.eq(row.status, "Installed")
                test.is_nil(row_of(installed, "shared"))

                -- The person shares the installed version with the hive from the Library.
                test.is_true(library.can_share(row), "made here " .. tostring(row.made_here) .. " source " .. row.source)
                local shared_request = governed.share_request(installed.governed, OVERLAY, "1.0.0")
                test.eq(shared_request.operation, "publish")
                local published = harness.value(harness.share(workspace, OVERLAY, "1.0.0"))
                test.is_true(published.published == true, json.encode(published))
                test.eq(published.version, "1.0.0")
            end)
            restore()
            if not done then error(tostring(failure)) end
        end)
    end)
end

return test.run_cases(define_tests)
