-- MIT. An approved workspace.files.watch grant gives the application one
-- folder it reads and watches; no filesystem operation writes, creates or
-- removes there, and the host-backed watch source behind it stays closed.
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local app_scope = require("app_scope")
local test = require("test")
local bounds = require("bounds")
local grants = require("capability_grants")
local model = require("capability_model")
local files = require("capability_files")

local WORKSPACE = string.rep("f", 32)
local NAME = "watchgrant"
local APP = "app." .. NAME .. ":app"
local OWNER = "bee.gov.apps:" .. WORKSPACE .. "." .. NAME
local OTHER_APP = "app.othergrant:app"
local OTHER_OWNER = "bee.gov.apps:" .. WORKSPACE .. ".othergrant"
local PROBE = "bee.tests.gov:watch_grant_probe"
local CALL_POLICY = "bee.tests.gov:watch_grant_call_policy"
local FOLDER = {root_ref = "bee.env:workspace_root", directory = ".", base = "project", subpath = ""}
local SUBPATH = "lua/gov/watch_grant_folder"
type Object = {[string]: unknown}

local function install(app: string, owner: string): (Object, {string})
    local vocabulary = assert(model.decode(assert(registry.get("bee.capability:catalog"))))
    local proposal = assert(grants.propose(vocabulary, owner, app, {
        {application = app, package = "test", capability = "workspace.files.watch", parameters = {subpath = SUBPATH},
            template_revision = 1, catalog_revision = model.revisions(vocabulary, "workspace.files.watch"),
            reason = "watch the folder"}}, nil, FOLDER))
    local policy = assert(bounds.object(proposal.policies[1]))
    local changes = assert(registry.snapshot()):changes()
    local created: {string} = {}
    local entries: {Object} = {policy}
    for _, volume in ipairs(proposal.volumes) do entries[#entries + 1] = assert(bounds.object(volume)) end
    for _, entry in ipairs(entries) do
        local id = assert(bounds.id(entry.id))
        if not registry.get(id) then
            changes:create({id = id, kind = assert(bounds.text(entry.kind, 160)),
                meta = assert(bounds.object(entry.meta)), data = entry.data})
            created[#created + 1] = id
        end
    end
    if #created > 0 then assert(changes:apply()) end
    return policy, created
end

local function remove(created: {string})
    if #created == 0 then return end
    local changes = assert(registry.snapshot()):changes()
    for _, id in ipairs(created) do changes:delete(id) end
    assert(changes:apply())
end

local function probe(policy: Object, folder: string, source: string): Object
    local actor = security.new_actor("bee.application:" .. WORKSPACE .. ":instance-1",
        {workspace_id = WORKSPACE, definition_id = APP, definition_revision = "1", execution_generation = 1})
    local scope = app_scope.boundary({assert(bounds.id(policy.id)), CALL_POLICY})
    local raw, err = funcs.new():with_actor(actor):with_scope(scope):call(PROBE, {folder = folder, source = source})
    if err then error(tostring(err)) end
    return assert(bounds.object(raw))
end

local function define_tests()
    test.describe("approved watch grant", function()
        test.it("reads and watches its own folder by its namespaced name and never writes, creates or removes there", function()
            local policy, created = install(APP, OWNER)
            local folder = assert(files.folder_id(APP, SUBPATH))
            local source = assert(files.watch_volume_id(OWNER, FOLDER, SUBPATH))
            local ok, result = pcall(probe, policy, folder, source)
            remove(created)
            assert(ok, tostring(result))
            test.eq(folder, "app.watchgrant:lua.gov.watch_grant_folder")
            test.eq(result.read, "A watch grant reads this file and can never change it.\n")
            test.is_true(result.watch_folder == true)
            test.is_false(result.writefile == true)
            test.is_false(result.open_write == true)
            test.is_false(result.mkdir == true)
            test.is_false(result.remove == true)
            test.is_false(result.source_get == true)
            test.is_false(result.watch_source == true)
        end)
        test.it("reaches no other application's folder", function()
            local policy, created = install(APP, OWNER)
            local other_policy, other_created = install(OTHER_APP, OTHER_OWNER)
            local ok, result = pcall(probe, policy, assert(files.folder_id(OTHER_APP, SUBPATH)),
                assert(files.watch_volume_id(OTHER_OWNER, FOLDER, SUBPATH)))
            remove(other_created)
            remove(created)
            assert(ok, tostring(result))
            test.not_nil(other_policy)
            test.is_nil(result.read)
            test.is_false(result.watch_folder == true)
            test.is_false(result.source_get == true)
        end)
    end)
end
return test.run_cases(define_tests)
