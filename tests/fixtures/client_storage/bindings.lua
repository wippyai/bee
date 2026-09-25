-- MIT. Native resource policies remain authoritative over store selection.
local store = require("store")
local workspace_store = require("workspace_store")
local state = require("state")
local sql = require("sql")
local function main(mode: string)
    local workspace_id = "0123456789abcdef0123456789abcdef"
    local left, left_error = store.open("bee.client.db:left", workspace_id)
    if not left then error(tostring(left_error)) end
    local right, right_error = store.open("bee.client.db:right", workspace_id)
    if not right then error(tostring(right_error)) end
    assert(left.client_id ~= right.client_id, "Client bindings share an identity")
    if mode == "seed" then
        assert(store.write(left, state.empty(91, 31)))
        assert(store.write(right, state.empty(112, 42)))
    else assert(mode == "verify") end
    local first, first_error = store.read(left)
    if not first then error(tostring(first_error)) end
    local second, second_error = store.read(right)
    if not second then error(tostring(second_error)) end
    assert(first.scene.width == 91 and second.scene.width == 112, "Client layouts crossed bindings")
    assert(store.close(left)); assert(store.close(right))
    local a, a_error = workspace_store.open("bee.workspace.db:left", {root_ref = "bee.env:workspace_root", subpath = ""})
    if not a then error(tostring(a_error)) end
    local b, b_error = workspace_store.open("bee.workspace.db:right", {root_ref = "bee.env:workspace_root", subpath = ""})
    if not b then error(tostring(b_error)) end
    local first_id, second_id = a:identity(), b:identity()
    assert(first_id and second_id and first_id ~= second_id, "Workspace bindings share an identity")
    if mode == "seed" then
        assert(a:write('{"version":1,"probe":"left"}'))
        assert(b:write('{"version":1,"probe":"right"}'))
    end
    assert(a:read() == '{"version":1,"probe":"left"}', "Left workspace state crossed bindings")
    assert(b:read() == '{"version":1,"probe":"right"}', "Right workspace state crossed bindings")
    assert(a:close()); assert(b:close())
    for _, resource in ipairs({"bee.env:workspace_db", "bee.workspace.db:left", "/tmp/client.db", "bee.client.db:*", "bee.client.db:", "bee.client.db:../left"}) do
        local rejected, err = store.open(resource, workspace_id)
        assert(not rejected and err == "Invalid client database binding", "Client store accepted a foreign binding")
    end
    local denied, denied_error = store.open("bee.client.db:forbidden", workspace_id)
    assert(not denied and denied_error, "A valid resource spelling bypassed native permission")
    local foreign, foreign_error = workspace_store.open("bee.client.db:left", {root_ref = "bee.env:workspace_root", subpath = ""})
    assert(not foreign and foreign_error == "Invalid workspace database binding")
end
local function denied()
    for _, resource in ipairs({"bee.env:client_db", "bee.env:workspace_db", "bee.client.db:left", "bee.client.db:right", "bee.workspace.db:left", "bee.workspace.db:right"}) do
        local handle, err = sql.get(resource)
        assert(not handle and err, "Broad database grant bypassed core storage boundary")
    end
end
return {main = main, denied = denied}
