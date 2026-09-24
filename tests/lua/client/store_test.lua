-- MIT. A client desktop keeps one layout per workspace it shows.
local test = require("test")
local sql = require("sql")
local json = require("json")
local store = require("store")
local state = require("state")
local model = require("model")
local appearance = require("appearance")

local LEFT = "0123456789abcdef0123456789abcdef"
local RIGHT = "ffffffffffffffffffffffffffffffff"

local function open(resource: string, workspace_id: string, desktop_id: string?): store.Store
    local handle, err = store.open(resource, workspace_id, desktop_id)
    if not handle then error("open client store: " .. tostring(err)) end
    return handle
end

local function sized(width: integer): state.State
    return state.empty(width, 24)
end

local function targeted(workspace_id: string): state.State
    local scene = model.add(model.new(100, 30), "view", "instance", "Terminal")
    return assert(state.import_desktop(workspace_id, {scene = scene, tabs = {"view"}, preferences = appearance.defaults()}))
end

-- Write a pre-keyed layout into the default desktop row, as a build before
-- per-workspace layouts left it.
local function legacy_layout(resource: string, value: state.State, import_workspace: string, receipt: string)
    local prepared = open(resource, LEFT)
    assert(store.close(prepared))
    local db = assert(sql.get(resource))
    local _, err = db:execute("UPDATE client_state SET value = ?, generation = 3, import_workspace = ?, import_receipt = ?",
        {assert(json.encode(value)), import_workspace, receipt})
    db:release()
    if err then error(tostring(err)) end
end

local function define_tests()
    test.describe("Client layouts per workspace", function()
        test.it("keeps one desktop identity and a separate layout for each workspace", function()
            local resource = "bee.client.db:layouts_test"
            local left = open(resource, LEFT)
            local right = open(resource, RIGHT)
            test.eq(left.client_id, right.client_id)
            test.is_nil(store.read(left))
            assert(store.write(left, sized(81)))
            test.is_nil(store.read(right))
            assert(store.write(right, sized(93)))
            assert(store.write(left, sized(82)))
            test.eq((assert(store.read(left))).scene.width, 82)
            test.eq((assert(store.read(right))).scene.width, 93)
            local stale = open(resource, RIGHT)
            assert(store.write(right, sized(94)))
            local written, stale_error = store.write(stale, sized(95))
            test.is_false(written)
            test.contains(tostring(stale_error), "changed")
            assert(store.close(left)); assert(store.close(right)); assert(store.close(stale))
            local _, invalid = store.open(resource, "not-a-workspace")
            test.contains(tostring(invalid), "Invalid workspace identity")
        end)

        test.it("imports older combined desktop state once per workspace", function()
            local resource = "bee.client.db:layouts_test"
            local fresh = "00000000000000000000000000000001"
            local other = "00000000000000000000000000000002"
            local first = open(resource, fresh)
            local desktop = {scene = model.add(model.new(100, 30), "view", "instance", "Terminal"), tabs = {"view"}, preferences = appearance.defaults()}
            local receipt = assert(store.import_legacy(first, fresh, desktop, "custom"))
            test.eq(assert(store.import_legacy(first, fresh, desktop, "custom")), receipt)
            local second = open(resource, other)
            local other_receipt = assert(store.import_legacy(second, other, desktop, "custom"))
            test.neq(other_receipt, receipt)
            local _, foreign = store.import_legacy(first, other, desktop, "custom")
            test.contains(tostring(foreign), "Invalid import workspace")
            test.eq((assert(store.read(first))).targets[1].workspace_id, fresh)
            assert(store.close(first)); assert(store.close(second))
        end)

        test.it("lets the workspace a pre-keyed layout names adopt it with its desktop identity", function()
            local resource = "bee.client.db:adoption_test"
            legacy_layout(resource, targeted(LEFT), "", "")
            local identity = assert(store.desktops(resource))
            local desktop_id = identity.client_id
            assert(store.release(identity))
            local right = open(resource, RIGHT)
            test.is_nil(store.read(right))
            assert(store.close(right))
            local left = open(resource, LEFT)
            test.eq(left.client_id, desktop_id)
            test.eq(left.generation, 3)
            local adopted = assert(store.read(left))
            test.eq(adopted.targets[1].workspace_id, LEFT)
            assert(store.write(left, adopted))
            assert(store.close(left))
            local db = assert(sql.get(resource))
            local rows = assert(db:query("SELECT generation, value FROM client_state"))
            db:release()
            test.eq(rows[1].generation, 0)
            test.is_nil(rows[1].value)
            local reopened = open(resource, LEFT)
            test.eq(reopened.generation, 4)
            assert(store.close(reopened))
        end)

        test.it("never lets a workspace adopt a layout imported for another workspace", function()
            local resource = "bee.client.db:foreign_adoption_test"
            legacy_layout(resource, sized(70), RIGHT, "abcdefabcdefabcdefabcdefabcdefab")
            local left = open(resource, LEFT)
            test.is_nil(store.read(left))
            assert(store.close(left))
            local right = open(resource, RIGHT)
            test.eq((assert(store.read(right))).scene.width, 70)
            assert(store.close(right))
        end)

        test.it("lists and allocates node desktops without a workspace", function()
            local desktops = assert(store.desktops("bee.client.db:layouts_test"))
            local listed = assert(store.catalog(desktops))
            test.eq(#listed, 1)
            test.is_true(listed[1].is_default)
            local extra = "abababababababababababababababab"
            assert(store.allocate(desktops, extra))
            test.eq(#(assert(store.catalog(desktops))), 2)
            assert(store.release(desktops))
            local left = open("bee.client.db:layouts_test", LEFT, extra)
            local right = open("bee.client.db:layouts_test", RIGHT, extra)
            assert(store.write(left, sized(60)))
            test.is_nil(store.read(right))
            assert(store.close(left)); assert(store.close(right))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
