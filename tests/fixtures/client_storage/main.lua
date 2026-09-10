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
    elseif mode == "desktops" then
        local first_id = string.rep("a", 32)
        local second_id = string.rep("b", 32)
        local missing, missing_error = store.open(nil, first_id)
        assert(not missing and missing_error == "Desktop identity not found")
        assert(store.allocate(left, first_id))
        assert(store.allocate(left, first_id))
        assert(store.allocate(left, second_id))
        local catalog, catalog_error = store.catalog(left)
        if not catalog then error(tostring(catalog_error)) end
        assert(#catalog == 3 and catalog[1].desktop_id == identity and catalog[1].is_default)
        assert(catalog[2].desktop_id == first_id and not catalog[2].is_default)
        assert(catalog[3].desktop_id == second_id and not catalog[3].is_default)
        local first, first_error = store.open(nil, first_id)
        if not first then error(tostring(first_error)) end
        local stale, stale_error = store.open(nil, first_id)
        if not stale then error(tostring(stale_error)) end
        local second, second_error = store.open(nil, second_id)
        if not second then error(tostring(second_error)) end
        assert(first.client_id == first_id and second.client_id == second_id)
        assert(store.write(first, state.empty(91, 29)))
        assert(store.write(second, state.empty(113, 37)))
        local overwritten, overwrite_error = store.write(stale, state.empty(66, 22))
        assert(not overwritten and overwrite_error, "Stale desktop writer was accepted")
        assert(read(first).scene.width == 91 and read(second).scene.width == 113)
        local imported, import_error = store.import_legacy(first, workspace_id, legacy())
        assert(not imported and import_error)
        local allocated, allocation_error = store.allocate(first, string.rep("c", 32))
        assert(not allocated and allocation_error)
        local catalog, catalog_error = store.catalog(first)
        assert(not catalog and catalog_error, "Selected desktop listed sibling identities")
        assert(read(left).scene.windows[1].user_title == "Edited after import")
        for index = 1, 30 do assert(store.allocate(left, string.format("%032x", index))) end
        local full, full_error = store.allocate(left, string.rep("d", 32))
        assert(not full and full_error == "Desktop capacity reached")
        assert(store.allocate(left, first_id), "Capacity rejected an identical allocation")
        assert(store.close(first)); assert(store.close(stale)); assert(store.close(second))
    elseif mode == "verify_desktops" then
        local catalog, catalog_error = store.catalog(left)
        if not catalog then error(tostring(catalog_error)) end
        assert(#catalog == 33 and catalog[1].desktop_id == identity and catalog[1].is_default)
        assert(catalog[32].desktop_id == string.rep("a", 32) and not catalog[32].is_default)
        assert(catalog[33].desktop_id == string.rep("b", 32) and not catalog[33].is_default)
        local first, first_error = store.open(nil, string.rep("a", 32))
        if not first then error(tostring(first_error)) end
        local second, second_error = store.open(nil, string.rep("b", 32))
        if not second then error(tostring(second_error)) end
        assert(read(first).scene.width == 91 and read(second).scene.width == 113)
        assert(read(left).scene.windows[1].user_title == "Edited after import")
        assert(store.close(first)); assert(store.close(second))
    elseif mode == "catalog" then
        local catalog, err = store.catalog(left)
        if not catalog then error(tostring(err)) end
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
    local catalog, catalog_error = store.catalog(left)
    assert(not catalog and catalog_error)
    local closed, closed_error = store.read(left)
    assert(not closed and closed_error)
    local written, write_error = store.write(left, state.empty(80, 24))
    assert(not written and write_error)
    local imported, import_error = store.import_legacy(left, workspace_id, legacy())
    assert(not imported and import_error)
end
return {main = main}
