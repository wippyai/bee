-- MIT. Native storage acceptance; the runner only supplies disposable files.
local store = require("store")
local state = require("state")
local model = require("model")
local appearance = require("appearance")
local workspace_id = "0123456789abcdef0123456789abcdef"
local function read(handle: store.Store): state.State
    local saved, err = store.read(handle)
    if not saved then error(tostring(err or "Missing client layout")) end
    return saved
end
local function legacy()
    local scene = model.add(model.new(100, 30), "view", "instance", "Terminal")
    scene = model.personalize(scene, "view", "Imported", "cyan")
    return {scene = scene, tabs = {"view"}, preferences = appearance.defaults()}
end
local function main(mode: string)
    local left, left_error = store.open()
    if not left then error(tostring(left_error)) end
    local identity = left.client_id
    if mode == "seed" then
        local right, right_error = store.open()
        if not right then error(tostring(right_error)) end
        assert(right.client_id == identity)
        local empty, empty_error = store.read(left)
        assert(not empty and not empty_error)
        local receipt, err = store.import_legacy(left, workspace_id, legacy())
        if not receipt then error(tostring(err)) end
        assert(#receipt == 32)
        local stale, stale_error = store.write(right, state.empty(80, 24))
        assert(not stale and stale_error, "Stale writer overwrote imported layout")
        assert(store.import_legacy(right, workspace_id, legacy()) == receipt)
        local loaded = read(left)
        assert(loaded.scene.windows[1].user_title == "Imported")
        assert(loaded.targets[1].workspace_id == workspace_id and loaded.targets[1].view_id == "view")
        assert(loaded.tabs[1] ~= "view" and loaded.scene.focus == loaded.tabs[1])
        assert(store.close(right))
    elseif mode == "edit" then
        local before = assert(store.import_legacy(left, workspace_id, legacy()))
        local saved: state.State = read(left)
        local tab_id = saved.tabs[1]
        if not tab_id then error("Missing imported tab") end
        saved.scene = model.personalize(saved.scene, tab_id, "Edited after import", "rose")
        assert(store.write(left, saved))
        assert(store.import_legacy(left, workspace_id, legacy()) == before)
        assert(read(left).scene.windows[1].user_title == "Edited after import")
    elseif mode == "verify" then
        local saved: state.State = read(left)
        assert(saved.scene.windows[1].user_title == "Edited after import")
        local receipt = assert(store.import_legacy(left, workspace_id, legacy()))
        assert(read(left).scene.windows[1].user_title == "Edited after import")
        local foreign, foreign_error = store.import_legacy(left, "ffffffffffffffffffffffffffffffff", legacy())
        assert(not foreign and foreign_error)
        assert(store.import_legacy(left, workspace_id, legacy()) == receipt)
    elseif mode == "existing" then
        assert(store.write(left, state.empty(80, 24)))
        local receipt, err = store.import_legacy(left, workspace_id, legacy())
        assert(not receipt and err, "Import overwrote a client-created layout")
        assert(#read(left).tabs == 0)
    elseif mode == "open" then
        local _, err = store.read(left)
        if err then error(err) end
    else error("Unknown client storage test mode") end
    assert(store.close(left))
    local closed, closed_error = store.read(left)
    assert(not closed and closed_error)
    local written, write_error = store.write(left, state.empty(80, 24))
    assert(not written and write_error)
    local imported, import_error = store.import_legacy(left, workspace_id, legacy())
    assert(not imported and import_error)
end
return {main = main}
