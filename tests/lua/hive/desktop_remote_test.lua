-- MIT. A remote view chooses its display from the owner's own listing: it
-- learns the owner execution, reuses a free display for control, allocates
-- only after definite controller refusals, observes the default display and
-- never retries.
local test = require("test")
local types = require("types")
local remote = require("remote")
local display = require("display")
type Object = {[string]: unknown}
local EXECUTION = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
local WORKSPACE = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
local FIRST = "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"
local SECOND = "c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2"
local FRESH = "f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0"
type Fake = {opened: {Object}, created: {string}, listed: integer, refuse: {[string]: string}, create_fault: string?, listing: unknown}
local function fake(listing: unknown): Fake
    return {opened = {}, created = {}, listed = 0, refuse = {}, create_fault = nil, listing = listing}
end
local function listing(ids: {string}): Object
    local desktops: {Object} = {}
    for index, id in ipairs(ids) do desktops[#desktops + 1] = {desktop_id = id, is_default = index == 1} end
    return {owner_execution = EXECUTION, desktops = desktops, workspaces = {}}
end
local function operations(f: Fake): remote.Operations
    return {
        list = function(): types.Reply
            f.listed = f.listed + 1
            return types.reply_ok("list", f.listing)
        end,
        create = function(execution: string, id: string): types.Reply
            f.created[#f.created + 1] = execution .. ":" .. id
            if f.create_fault then return types.reply_error("create", types.fault(f.create_fault, "refused")) end
            return types.reply_ok("create", {owner_execution = execution, desktop_id = id})
        end,
        open = function(target: display.Target): (display.Handle?, display.Fault?)
            f.opened[#f.opened + 1] = {desktop_id = target.desktop_id, execution = target.owner_execution, mode = target.mode,
                workspace_id = target.workspace_id, node_id = target.node_id}
            local code = f.refuse[target.desktop_id]
            if code then
                local fault: display.Fault = {code = code, message = "refused"}
                return nil, fault
            end
            local handle: display.Handle = {id = "session-" .. target.desktop_id}
            return handle, nil
        end,
        new_id = function(): string return FRESH end,
    }
end
local function define_tests()
    test.describe("Remote desktop view selection", function()
        test.it("attaches control to the first free display under the listed execution", function()
            local f = fake(listing({FIRST, SECOND}))
            f.refuse[FIRST] = "DESKTOP_CONTROLLED"
            local opened, fault = remote.choose(operations(f), "node-b", WORKSPACE, "control")
            test.is_nil(fault)
            test.eq(opened and opened.target.desktop_id, SECOND)
            test.eq(opened and opened.target.owner_execution, EXECUTION)
            test.eq(#f.opened, 2)
            test.eq(f.opened[1].node_id, "node-b")
            test.eq(f.opened[1].workspace_id, WORKSPACE)
            test.eq(#f.created, 0)
        end)
        test.it("allocates a display only after every one is controlled", function()
            local f = fake(listing({FIRST}))
            f.refuse[FIRST] = "DESKTOP_CONTROLLED"
            local opened = remote.choose(operations(f), "node-b", WORKSPACE, "control")
            test.eq(opened and opened.target.desktop_id, FRESH)
            test.eq(f.created[1], EXECUTION .. ":" .. FRESH)
        end)
        test.it("returns any other refusal without trying further displays", function()
            local f = fake(listing({FIRST, SECOND}))
            f.refuse[FIRST] = "DENIED"
            local opened, fault = remote.choose(operations(f), "node-b", WORKSPACE, "control")
            test.is_nil(opened)
            test.eq(fault and fault.code, "DENIED")
            test.eq(#f.opened, 1)
            test.eq(#f.created, 0)
            local uncertain = fake(listing({FIRST}))
            uncertain.refuse[FIRST] = "DESKTOP_CONTROLLED"
            uncertain.create_fault = "UNCERTAIN"
            local _, create_fault = remote.choose(operations(uncertain), "node-b", WORKSPACE, "control")
            test.eq(create_fault and create_fault.code, "UNCERTAIN")
            test.eq(#uncertain.opened, 1)
        end)
        test.it("observes the default display and never allocates", function()
            local f = fake(listing({FIRST, SECOND}))
            local opened = remote.choose(operations(f), "node-b", WORKSPACE, "observe")
            test.eq(opened and opened.target.desktop_id, FIRST)
            test.eq(opened and opened.target.mode, "observe")
            local none = fake(listing({}))
            local _, fault = remote.choose(operations(none), "node-b", WORKSPACE, "observe")
            test.eq(fault and fault.code, "NOT_FOUND")
            test.eq(#none.created, 0)
        end)
        test.it("refuses a listing refusal or a malformed listing", function()
            local denied = fake(nil)
            local ops = operations(denied)
            ops.list = function(): types.Reply return types.reply_error("list", types.fault("DENIED", "not admitted")) end
            local _, fault = remote.choose(ops, "node-b", WORKSPACE, "control")
            test.eq(fault and fault.code, "DENIED")
            local malformed = fake({owner_execution = "short", desktops = {}})
            local _, invalid = remote.choose(operations(malformed), "node-b", WORKSPACE, "control")
            test.eq(invalid and invalid.code, "INVALID_STATE")
            test.eq(#malformed.opened, 0)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
