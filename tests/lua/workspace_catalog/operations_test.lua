-- MIT. The catalog owner operations: each is authorized for the caller and
-- the exact workspace or root it names, runs under the host-named execution
-- scope, and keeps every folder under a root the host admitted.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local process = require("process")
local time = require("time")
local fs = require("fs")

local PROJECTS = "bee.workspace.catalog:projects_fixture"
local ARCHIVE = "bee.workspace.catalog:readonly_fixture"
local UNADMITTED = "bee.workspace.catalog:unadmitted_fixture"
local CALL = "bee.workspace.catalog:call_test_policy"

type Object = {[string]: unknown}
type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown}

local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end

local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end

local function caller(id: string, grants: {string}): funcs.Executor
    local names: {string} = {CALL}
    for _, grant in ipairs(grants) do names[#names + 1] = grant end
    return funcs.new():with_actor(security.new_actor(id)):with_scope(scope(names))
end

-- A manager, a reader, a principal with neither grant, and an application
-- principal behind the application storage boundary with both grants.
local manager = caller("bee.test.catalog_manager", {"bee.security.storage:workspace_catalog_read_policy", "bee.security.storage:workspace_catalog_manage_policy"})
local reader = caller("bee.test.catalog_reader", {"bee.security.storage:workspace_catalog_read_policy"})
local outsider = caller("bee.test.catalog_outsider", {})
local browser = caller("bee.test.catalog_browser", {"bee.security.storage:workspace_folder_browse_policy"})
local application = caller("bee.test.catalog_application", {"bee.security.storage:workspace_storage_boundary", "bee.security:ordinary_app_subsystem_boundary",
    "bee.security.storage:workspace_catalog_read_policy", "bee.security.storage:workspace_catalog_manage_policy"})

local function call(client: funcs.Executor, method: string, value: unknown): Reply
    local reply, err = client:call("bee.workspace.catalog:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    if type(reply) ~= "table" then error(method .. ": missing reply") end
    return reply :: Reply
end

local function value(reply: Reply): Object
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: Object
end

local function code(reply: Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end

local admitted = false
local function admit_roots()
    if admitted then return end
    admitted = true
    local entry = registry.get("bee:resource_roots")
    if not entry then error("admitted roots entry") end
    local data = entry.data :: Object
    local roots = data.roots :: {Object}
    roots[#roots + 1] = {root_ref = PROJECTS, access = "write"}
    roots[#roots + 1] = {root_ref = ARCHIVE, access = "read"}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("admit roots: " .. tostring(err)) end
end

local function folder(root_ref: string, name: string): string
    local volume = assert(fs.get(root_ref))
    if not volume:exists(name) then assert(volume:mkdir(name)) end
    return name
end

local function create(label: string, subpath: string, root_ref: string?): Object
    return value(call(manager, "create", {label = label, root_ref = root_ref or PROJECTS, subpath = subpath}))
end

local function define_tests()
    test.describe("Workspace catalog operations", function()
        test.it("creates a workspace for an existing folder under an admitted root and reads it back", function()
            admit_roots()
            local name = folder(PROJECTS, fresh("existing"))
            local created = create("Existing " .. name, name)
            test.eq(#tostring(created.workspace_id), 32)
            test.eq(created.state, "active")
            test.eq(created.root_ref, PROJECTS)
            test.eq(created.subpath, name)
            local read = value(call(reader, "read", {workspace_id = created.workspace_id}))
            test.eq((read.workspace :: Object).label, "Existing " .. name)
            test.eq(read.live, false)
            test.eq(code(call(manager, "create", {label = "Again", root_ref = PROJECTS, subpath = name})), "CONFLICT")
        end)

        test.it("makes a new folder under a write-admitted root inside the create", function()
            admit_roots()
            local parent = folder(PROJECTS, fresh("parent"))
            local subpath = parent .. "/fresh"
            local created = value(call(manager, "create", {label = "Fresh", root_ref = PROJECTS, subpath = subpath, create_directory = true}))
            test.eq(created.subpath, subpath)
            local volume = assert(fs.get(PROJECTS))
            test.is_true(volume:isdir(subpath))
            test.eq(code(call(manager, "create", {label = "Twice", root_ref = PROJECTS, subpath = subpath, create_directory = true})), "CONFLICT")
            test.eq(code(call(manager, "create", {label = "Orphan", root_ref = PROJECTS, subpath = fresh("missing") .. "/child",
                create_directory = true})), "NOT_FOUND")
        end)

        test.it("keeps every folder under a root the host admitted, at the access it admitted", function()
            admit_roots()
            test.eq(code(call(manager, "create", {label = "Outside", root_ref = UNADMITTED, subpath = ""})), "FORBIDDEN")
            test.eq(code(call(manager, "create", {label = "Read only", root_ref = ARCHIVE, subpath = fresh("new"), create_directory = true})), "FORBIDDEN")
            local readable = folder(ARCHIVE, fresh("archive"))
            test.eq(value(call(manager, "create", {label = "Read only folder", root_ref = ARCHIVE, subpath = readable})).root_ref, ARCHIVE)
            test.eq(code(call(manager, "create", {label = "Missing", root_ref = PROJECTS, subpath = fresh("absent")})), "NOT_FOUND")
            test.eq(code(call(manager, "create", {label = "Escape", root_ref = PROJECTS, subpath = "../outside"})), "INVALID")
            test.eq(code(call(manager, "create", {label = "Absolute", root_ref = PROJECTS, subpath = "/etc"})), "INVALID")
            test.eq(code(call(manager, "create", {label = "", root_ref = PROJECTS, subpath = "x"})), "INVALID")
            test.eq(code(call(manager, "create", {label = "Two\nlines", root_ref = PROJECTS, subpath = "x"})), "INVALID")
            test.eq(code(call(manager, "create", {label = "Owner", root_ref = PROJECTS, subpath = "x", owner = "me"})), "INVALID")
        end)

        test.it("pages and searches through the operations, with the same cursor", function()
            admit_roots()
            local stem = fresh("paging")
            local base = folder(PROJECTS, stem)
            for index = 1, 7 do
                create(stem .. " " .. tostring(index), folder(PROJECTS, base .. "/" .. tostring(index)))
            end
            local labels: {string} = {}
            local after: unknown = nil
            repeat
                local request: Object = {label = stem, limit = 3}
                if after then request.after = after end
                local page = value(call(reader, "search", request))
                for _, item in ipairs(page.items :: {Object}) do labels[#labels + 1] = tostring(item.label) end
                after = page.next_after
            until after == nil
            test.eq(#labels, 7)
            test.eq(labels[1], stem .. " 1")
            test.eq(labels[7], stem .. " 7")
            local under = value(call(reader, "search", {root_ref = PROJECTS, path = base, limit = 100}))
            test.eq(#(under.items :: {Object}), 7)
            local listed = value(call(reader, "list", {limit = 2}))
            test.eq(#(listed.items :: {Object}), 2)
            test.not_nil(listed.next_after)
            test.eq(code(call(reader, "list", {after = "forged"})), "INVALID")
            test.eq(code(call(reader, "list", {limit = 101})), "INVALID")
            test.eq(code(call(reader, "search", {label = stem, root_ref = PROJECTS})), "INVALID")
            test.eq(code(call(reader, "search", {})), "INVALID")
        end)

        test.it("searches one folder path under every admitted root, root by root", function()
            admit_roots()
            local base = fresh("across")
            local projects = create("Across projects", folder(PROJECTS, base))
            -- The same folder name under a second admitted root.
            local archive_volume = assert(fs.get(ARCHIVE))
            if not archive_volume:exists(base) then assert(archive_volume:mkdir(base)) end
            local archived = create("Across archive", base, ARCHIVE)
            local found: {Object} = {}
            local after: unknown = nil
            repeat
                local request: Object = {path = base, limit = 1}
                if after then request.after = after end
                local page = value(call(reader, "search", request))
                for _, item in ipairs(page.items :: {Object}) do found[#found + 1] = item end
                after = page.next_after
            until after == nil
            test.eq(#found, 2)
            local first_root, second_root = PROJECTS, ARCHIVE
            if ARCHIVE < PROJECTS then first_root, second_root = ARCHIVE, PROJECTS end
            test.eq(found[1].root_ref, first_root)
            test.eq(found[2].root_ref, second_root)
            local wanted = {[tostring(projects.workspace_id)] = true, [tostring(archived.workspace_id)] = true}
            test.is_true(wanted[tostring(found[1].workspace_id)] == true)
            test.is_true(wanted[tostring(found[2].workspace_id)] == true)
            test.is_true(found[1].workspace_id ~= found[2].workspace_id)
            test.eq(code(call(reader, "search", {path = base, label = "Across"})), "INVALID")
        end)

        test.it("lists the roots the host admits with the access it admits", function()
            admit_roots()
            local listed = value(call(reader, "roots", {}))
            local access: {[string]: string} = {}
            local previous = ""
            for _, root in ipairs(listed.roots :: {Object}) do
                local ref = tostring(root.root_ref)
                test.is_true(ref > previous)
                previous = ref
                access[ref] = tostring(root.access)
            end
            test.eq(access[PROJECTS], "write")
            test.eq(access[ARCHIVE], "read")
            test.is_nil(access[UNADMITTED])
            test.eq(code(call(outsider, "roots", {})), "DENIED")
            test.eq(code(call(reader, "roots", {root_ref = PROJECTS})), "INVALID")
        end)

        test.it("pages the folders inside a folder of an admitted root and names the workspaces they hold", function()
            admit_roots()
            local base = folder(PROJECTS, fresh("browse"))
            for _, name in ipairs({"beta", "alpha", "gamma", ".hidden"}) do folder(PROJECTS, base .. "/" .. name) end
            local volume = assert(fs.get(PROJECTS))
            assert(volume:writefile(base .. "/notes.txt", "not a folder"))
            local held = create("Held beta", base .. "/beta")
            local own = create("Browse base", base)
            local first = value(call(manager, "folders", {root_ref = PROJECTS, path = base, limit = 2}))
            test.eq(first.root_ref, PROJECTS)
            test.eq(first.path, base)
            test.eq(first.access, "write")
            test.eq(first.workspace_id, own.workspace_id)
            local items = first.folders :: {Object}
            test.eq(#items, 2)
            test.eq(items[1].name, "alpha")
            test.is_nil(items[1].workspace_id)
            test.eq(items[2].name, "beta")
            test.eq(items[2].workspace_id, held.workspace_id)
            test.not_nil(first.next_after)
            local second = value(call(manager, "folders", {root_ref = PROJECTS, path = base, limit = 2, after = first.next_after}))
            local rest = second.folders :: {Object}
            test.eq(#rest, 1)
            test.eq(rest[1].name, "gamma")
            test.is_nil(second.next_after)
            local top = value(call(manager, "folders", {root_ref = ARCHIVE}))
            test.eq(top.path, "")
            test.eq(top.access, "read")
            test.eq(code(call(manager, "folders", {root_ref = UNADMITTED})), "FORBIDDEN")
            test.eq(code(call(manager, "folders", {root_ref = PROJECTS, path = base .. "/absent"})), "NOT_FOUND")
            test.eq(code(call(manager, "folders", {root_ref = PROJECTS, path = base .. "/notes.txt"})), "NOT_FOUND")
            test.eq(code(call(manager, "folders", {root_ref = PROJECTS, path = "../outside"})), "INVALID")
            test.eq(code(call(manager, "folders", {root_ref = PROJECTS, after = "a/b"})), "INVALID")
            test.eq(code(call(reader, "folders", {root_ref = PROJECTS, path = base})), "DENIED")
            -- Browsing folders is its own grant: it pages folders and lists
            -- the roots, and creates nothing.
            local browsed = value(call(browser, "folders", {root_ref = PROJECTS, path = base, limit = 2}))
            test.eq(#(browsed.folders :: {Object}), 2)
            test.not_nil(value(call(browser, "roots", {})).roots)
            test.eq(code(call(browser, "create", {label = "Browsed", root_ref = PROJECTS, subpath = base .. "/alpha"})), "DENIED")
            test.eq(code(call(browser, "archive", {workspace_id = own.workspace_id})), "DENIED")
            test.eq(code(call(browser, "inspect", {workspace_id = own.workspace_id})), "DENIED")
        end)

        test.it("renames, archives and restores, replaying a repeated change", function()
            admit_roots()
            local created = create("Before", folder(PROJECTS, fresh("lifecycle")))
            local id = created.workspace_id
            test.eq(value(call(manager, "rename", {workspace_id = id, label = "After"})).label, "After")
            test.eq(value(call(manager, "archive", {workspace_id = id})).state, "archived")
            test.eq(value(call(manager, "archive", {workspace_id = id})).state, "archived")
            local archived = value(call(reader, "search", {label = "After", state = "archived", limit = 100}))
            local found = false
            for _, item in ipairs(archived.items :: {Object}) do if item.workspace_id == id then found = true end end
            test.is_true(found)
            test.eq(value(call(manager, "restore", {workspace_id = id})).state, "active")
            test.eq(value(call(manager, "restore", {workspace_id = id})).state, "active")
            test.eq(code(call(manager, "rename", {workspace_id = string.rep("0", 32), label = "Nobody"})), "NOT_FOUND")
            test.eq(code(call(manager, "archive", {workspace_id = string.rep("0", 32)})), "NOT_FOUND")
        end)

        test.it("refuses to archive a workspace while its host runs", function()
            admit_roots()
            local id = tostring(create("Served", folder(PROJECTS, fresh("served"))).workspace_id)
            local name = "bee.workspace.host/" .. id
            assert(process.registry.register(name))
            local busy = call(manager, "archive", {workspace_id = id})
            test.eq(value(call(reader, "read", {workspace_id = id})).live, true)
            process.registry.unregister(name)
            test.eq(code(busy), "BUSY")
            test.eq(value(call(manager, "archive", {workspace_id = id})).state, "archived")
        end)

        test.it("authorizes each operation for the caller", function()
            admit_roots()
            local id = tostring(create("Guarded", folder(PROJECTS, fresh("guarded"))).workspace_id)
            test.eq(code(call(outsider, "list", {})), "DENIED")
            test.eq(code(call(outsider, "read", {workspace_id = id})), "DENIED")
            test.eq(code(call(reader, "rename", {workspace_id = id, label = "Taken"})), "DENIED")
            test.eq(code(call(reader, "archive", {workspace_id = id})), "DENIED")
            test.eq(code(call(reader, "create", {label = "Nope", root_ref = PROJECTS, subpath = folder(PROJECTS, fresh("nope"))})), "DENIED")
            local backend, backend_error = outsider:call("bee.workspace.catalog:backend", {operation = "list", request = {}})
            test.is_true(backend_error ~= nil or (type(backend) == "table" and backend.ok == false))
        end)

        test.it("serves an application principal whose storage boundary denies the node store", function()
            admit_roots()
            local created = value(call(application, "create", {label = "From an app", root_ref = PROJECTS, subpath = folder(PROJECTS, fresh("app"))}))
            test.eq(value(call(application, "read", {workspace_id = created.workspace_id})).live, false)
            test.eq(#(value(call(application, "search", {label = "From an app", limit = 5})).items :: {Object}) >= 1, true)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
