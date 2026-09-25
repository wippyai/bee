-- MIT. The Workspaces create flow: a folder picked from the host's admitted
-- roots and their folders, a label, and a new folder only under a root the
-- host admits for writing. Every owner answer is bounded before it is shown.
local test = require("test")
local creation = require("creation")
local folder_picker = require("folder_picker")
local caller = require("caller")

type Object = {[string]: unknown}

local ID = string.rep("a", 32)
local HELD = string.rep("b", 32)

local function ok(value: unknown): caller.Reply
    return {ok = true, error = nil, value = value, replayed = false}
end

local function refused(code: string, message: string): caller.Reply
    return {ok = false, error = {code = code, message = message}, value = nil, replayed = false}
end

local function roots(): caller.Reply
    return ok({roots = {{root_ref = "bee.environment:workspace_root", access = "write"}, {root_ref = "bee:archive", access = "read"},
        {root_ref = "\27[2J", access = "write"}, "junk"}})
end

local function listing(path: string, folders: {Object}, extra: Object?): caller.Reply
    local value: Object = {root_ref = "bee.environment:workspace_root", path = path, access = "write", folders = folders}
    for key, item in pairs(extra or {}) do value[key] = item end
    return ok(value)
end

local function define_tests()
    test.describe("Workspaces create flow", function()
        test.it("starts from a launch argument", function()
            test.is_true(creation.requested({"create"}))
            test.is_false(creation.requested({}))
            test.is_false(creation.requested({"archive"}))
        end)

        test.it("picks an existing folder under an admitted root and names the workspace after it", function()
            local form = creation.new()
            test.eq(folder_picker.roots_intent().target, "bee.workspace.catalog:roots")
            folder_picker.apply_roots(form.picker, roots())
            test.eq(#form.picker.roots, 2)
            test.is_nil(folder_picker.folders_intent(form.picker))
            test.is_true(folder_picker.open(form.picker))
            local first = folder_picker.folders_intent(form.picker)
            test.eq(first and first.target, "bee.workspace.catalog:folders")
            test.eq(first and first.request.root_ref, "bee.environment:workspace_root")
            test.eq(first and first.request.path, "")
            test.eq(first and first.request.limit, folder_picker.PAGE)
            folder_picker.apply_folders(form.picker, listing("", {{name = "alpha"}, {name = "beta", workspace_id = HELD}}))
            test.eq(#form.picker.folders, 2)
            test.eq(form.picker.folders[2].workspace_id, HELD)
            test.eq(folder_picker.move(form.picker, 1), "select")
            test.is_true(folder_picker.open(form.picker))
            test.eq(folder_picker.folders_intent(form.picker) and folder_picker.folders_intent(form.picker).request.path, "beta")
            folder_picker.apply_folders(form.picker, listing("beta", {{name = "docs"}}, {workspace_id = HELD}))
            test.eq(form.picker.held, HELD)
            test.is_true(creation.use(form))
            test.eq(form.step, "details")
            test.eq(form.label, "beta")
            -- The folder is a workspace already; only a new folder inside it can be one.
            test.is_nil(creation.intent(form))
            test.eq(form.failure, "beta is a workspace already; name a new folder inside it")
            creation.field(form, 1)
            creation.type_text(form, "gamma")
            test.eq(form.label, "gamma")
            local intent = creation.intent(form)
            test.eq(intent and intent.target, "bee.workspace.catalog:create")
            test.eq(intent and intent.request.label, "gamma")
            test.eq(intent and intent.request.root_ref, "bee.environment:workspace_root")
            test.eq(intent and intent.request.subpath, "beta/gamma")
            test.eq(intent and intent.request.create_directory, true)
            local created = creation.apply_created(form, ok({workspace_id = ID, label = "gamma", root_ref = "bee.environment:workspace_root",
                subpath = "beta/gamma", state = "active", created_at = "2026-09-24T00:00:00.000Z", last_used_at = "2026-09-24T00:00:00.000Z"}))
            test.eq(created and created.workspace_id, ID)
        end)

        test.it("keeps an edited label and uses the chosen folder itself", function()
            local form = creation.new()
            folder_picker.apply_roots(form.picker, roots())
            folder_picker.open(form.picker)
            folder_picker.apply_folders(form.picker, listing("", {{name = "alpha"}}))
            test.is_true(folder_picker.open(form.picker))
            folder_picker.apply_folders(form.picker, listing("alpha", {}))
            creation.use(form)
            creation.erase(form)
            creation.type_text(form, "X")
            test.eq(form.label, "alphX")
            creation.field(form, 1)
            creation.type_text(form, "new")
            test.eq(form.label, "alphX")
            creation.erase(form); creation.erase(form); creation.erase(form)
            local intent = creation.intent(form)
            test.eq(intent and intent.request.subpath, "alpha")
            test.is_nil(intent and intent.request.create_directory)
        end)

        test.it("offers a new folder only under a root admitted for writing and checks what was typed", function()
            local form = creation.new()
            folder_picker.apply_roots(form.picker, roots())
            folder_picker.move(form.picker, 1)
            folder_picker.open(form.picker)
            folder_picker.apply_folders(form.picker, ok({root_ref = "bee:archive", path = "", access = "read", folders = {}}))
            test.is_false(creation.writable(form))
            creation.use(form)
            test.eq(form.label, "bee:archive")
            creation.field(form, 1)
            test.eq(form.field, 1)
            while form.label ~= "" do creation.erase(form) end
            test.is_nil(creation.intent(form))
            test.eq(form.failure, "Name the workspace")
            creation.type_text(form, "Line\nbreak")
            test.eq(form.label, "")
            local writable = creation.new()
            folder_picker.apply_roots(writable.picker, roots())
            folder_picker.open(writable.picker)
            folder_picker.apply_folders(writable.picker, listing("", {}))
            creation.use(writable)
            creation.field(writable, 1)
            creation.type_text(writable, "a/b")
            test.is_nil(creation.intent(writable))
            test.eq(writable.failure, "A new folder is one name, without / and not . or ..")
        end)

        test.it("pages folders with the owner's cursor and walks back up to the roots", function()
            local form = creation.new()
            folder_picker.apply_roots(form.picker, roots())
            folder_picker.open(form.picker)
            local names: {Object} = {}
            for index = 1, folder_picker.PAGE do names[index] = {name = string.format("f%03d", index)} end
            folder_picker.apply_folders(form.picker, listing("", names, {next_after = "f050"}))
            test.eq(#form.picker.folders, folder_picker.PAGE)
            for _ = 1, folder_picker.PAGE - 1 do test.eq(folder_picker.move(form.picker, 1), "select") end
            test.eq(folder_picker.move(form.picker, 1), "page")
            test.eq(folder_picker.folders_intent(form.picker) and folder_picker.folders_intent(form.picker).request.after, "f050")
            folder_picker.apply_folders(form.picker, listing("", {{name = "g"}}))
            test.eq(folder_picker.move(form.picker, -1), "page")
            test.is_nil(folder_picker.folders_intent(form.picker) and folder_picker.folders_intent(form.picker).request.after)
            folder_picker.apply_folders(form.picker, listing("", {{name = "one"}}))
            test.is_true(folder_picker.open(form.picker))
            folder_picker.apply_folders(form.picker, listing("one", {{name = "two"}}))
            test.is_true(folder_picker.open(form.picker))
            test.eq(form.picker.path, "one/two")
            test.is_true(folder_picker.up(form.picker))
            test.eq(form.picker.path, "one")
            test.is_true(folder_picker.up(form.picker))
            test.eq(form.picker.path, "")
            test.is_false(folder_picker.up(form.picker))
            test.is_nil(form.picker.root)
        end)

        test.it("keeps the form and says why when the owner refuses", function()
            local form = creation.new()
            folder_picker.apply_roots(form.picker, refused("DENIED", "no roots"))
            test.eq(form.picker.error, "DENIED: no roots")
            folder_picker.apply_roots(form.picker, roots())
            folder_picker.open(form.picker)
            folder_picker.apply_folders(form.picker, refused("NOT_FOUND", "folder x does not exist\27[2J"))
            test.is_nil(tostring(form.picker.error):find("\27", 1, true))
            folder_picker.apply_folders(form.picker, listing("", {{name = "a"}, {name = "b/c"}, {name = ".."}}))
            test.eq(#form.picker.folders, 1)
            test.is_nil(form.picker.error)
            creation.use(form)
            test.eq(creation.back(form), true)
            test.eq(form.step, "folder")
            creation.use(form)
            local intent = creation.intent(form)
            test.not_nil(intent)
            test.is_nil(creation.apply_created(form, refused("CONFLICT", "a workspace already holds this folder")))
            test.eq(form.failure, "CONFLICT: a workspace already holds this folder")
            test.eq(form.step, "details")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
