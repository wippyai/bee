-- MIT. The protected kernel is built from the declarations kernel components
-- ship with their entries, never from a central id list.
local test = require("test")
local registry = require("registry")
local protected_kernel = require("protected_kernel")
local super_edit = require("super_edit")
local baseline = require("protected_baseline")

type Row = {[string]: unknown}

local HOST = "acme/host"

local function row(id: string, kind: string, module: string?, meta: {[string]: unknown}?, data: {[string]: unknown}?): Row
    return {id = id, kind = kind, meta = meta or {}, data = data or {},
        registry = {owner = module or "", root = false}}
end

local function declaration(namespace: string, scope: unknown, module: string?): Row
    return row(namespace .. ":kernel", "registry.entry", module or HOST, {type = "bee.kernel"}, {scope = scope})
end

local function trust_map(super_edit_ids: {string}?): Row
    return row("bee.gov:protected_kernel", "registry.entry", HOST, {type = "bee.protected_kernel"},
        {revision = 1, super_edit = super_edit_ids or {}})
end

local function base(): {Row}
    return {trust_map(), declaration("bee.gov", "tree"), declaration("host.core", "tree"),
        row("host.core:service", "library.lua", HOST)}
end

local function build(rows: {Row}): (protected_kernel.Manifest?, {string}?, string?)
    return protected_kernel.build(rows)
end

local function shipped(): protected_kernel.Manifest
    local snapshot = assert(registry.snapshot())
    local state = assert(snapshot:state())
    local manifest, _, build_error = protected_kernel.build(state.entries)
    if not manifest then error(tostring(build_error)) end
    return manifest
end

local function define_tests()
    test.describe("protected kernel declarations", function()
        test.it("protects an entry added to or moved within a declared component without a list", function()
            local rows = base()
            rows[#rows + 1] = row("host.core:added", "function.lua", HOST)
            rows[#rows + 1] = row("host.core.persist:moved", "library.lua", HOST)
            local manifest, sources = build(rows)
            local built = assert(manifest)
            test.is_true(protected_kernel.names(built, "host.core:service"))
            test.is_true(protected_kernel.names(built, "host.core:added"))
            test.is_true(protected_kernel.names(built, "host.core.persist:moved"))
            test.is_true(protected_kernel.names(built, "host.core:kernel"))
            test.is_true(protected_kernel.names(built, "bee.gov:protected_kernel"))
            test.eq(table.concat(assert(sources), ","), "bee.gov:kernel,bee.gov:protected_kernel,host.core:kernel")
        end)
        test.it("leaves application, overlay-authored and other modules' entries governed", function()
            local rows = base()
            rows[#rows + 1] = row("app.tally:main", "process.lua", nil)
            rows[#rows + 1] = row("host.core:shadow", "library.lua", nil)
            rows[#rows + 1] = row("host.core.vendor:tool", "library.lua", "vendor/tool")
            rows[#rows + 1] = row("host.other:app", "process.lua", HOST)
            local built = assert((build(rows)))
            test.is_false(protected_kernel.names(built, "app.tally:main"))
            test.is_false(protected_kernel.names(built, "host.core:shadow"))
            test.is_false(protected_kernel.names(built, "host.core.vendor:tool"))
            test.is_false(protected_kernel.names(built, "host.other:app"))
        end)
        test.it("covers only its own namespace when the declaration's scope is namespace", function()
            local rows = base()
            rows[#rows + 1] = declaration("host", "namespace")
            rows[#rows + 1] = row("host:wiring", "registry.entry", HOST)
            rows[#rows + 1] = row("host.driver.stub:binding", "library.lua", HOST)
            local built = assert((build(rows)))
            test.is_true(protected_kernel.names(built, "host:wiring"))
            test.is_false(protected_kernel.names(built, "host.driver.stub:binding"))
        end)
        test.it("gives an overlay-authored declaration no members", function()
            local rows = base()
            rows[#rows + 1] = declaration("app.tally", "tree", "")
            rows[#rows + 1] = row("app.tally:main", "process.lua", nil)
            local built = assert((build(rows)))
            test.is_false(protected_kernel.names(built, "app.tally:main"))
            test.is_false(protected_kernel.names(built, "app.tally:kernel"))
        end)
        test.it("refuses a malformed or ambiguous declaration", function()
            local malformed: {Row} = {
                declaration("host.core.bad", "everything"),
                declaration("host.core.bad", nil),
                row("host.core.bad:kernel", "registry.entry", HOST, {type = "bee.kernel"}, {scope = "tree", note = "x"}),
                row("host.core.bad:kernel", "library.lua", HOST, {type = "bee.kernel"}, {scope = "tree"}),
                row("host.core:second", "registry.entry", HOST, {type = "bee.kernel"}, {scope = "tree"}),
            }
            for index, bad in ipairs(malformed) do
                local rows = base()
                rows[#rows + 1] = bad
                local manifest, sources, build_error = build(rows)
                test.is_nil(manifest, tostring(index))
                test.is_nil(sources, tostring(index))
                test.not_nil(build_error, tostring(index))
            end
        end)
        test.it("refuses a missing, malformed or unprotected trust map", function()
            local missing = base()
            table.remove(missing, 1)
            test.is_nil((build(missing)))
            local listed = base()
            listed[1] = row("bee.gov:protected_kernel", "registry.entry", HOST, {type = "bee.protected_kernel"},
                {revision = 1, super_edit = {}, entries = {"bee.gov:protected_kernel"}})
            test.is_nil((build(listed)))
            local unprotected = base()
            table.remove(unprotected, 2)
            local manifest, _, build_error = build(unprotected)
            test.is_nil(manifest)
            test.not_nil((string.find(tostring(build_error), "protect itself", 1, true)))
        end)
        test.it("keeps the trust map's exact super-edit set", function()
            local rows = base()
            rows[1] = trust_map({"host.core:service"})
            local built = assert((build(rows)))
            test.is_true(protected_kernel.opened(built, "host.core:service"))
            test.is_false(protected_kernel.opened(built, "host.core:added"))
        end)
    end)
    test.describe("shipped protected kernel", function()
        test.it("protects every definition the former central list named that still ships", function()
            local manifest = shipped()
            local snapshot = assert(registry.snapshot())
            local present = 0
            for _, id in ipairs(baseline) do
                local entry = snapshot:get(id)
                if entry then
                    present = present + 1
                    test.is_true(protected_kernel.names(manifest, id), id)
                end
            end
            test.is_true(present > 1300)
            test.is_true(#manifest.entries > #baseline)
        end)
        test.it("protects entries that moved out of the former list's namespaces", function()
            local manifest = shipped()
            for _, id in ipairs({"bee.node.persist:workspaces", "bee.threads.persist:session_store",
                "bee.hive.persist:receipts", "bee.docs:manuals", "bee.ui:markdown", "bee.process:worker",
                "bee.harness:classification", "bee.node.service.owner:instance"}) do
                test.is_true(protected_kernel.names(manifest, id), id)
            end
        end)
        test.it("leaves the shipped drivers' own namespaces governed", function()
            local manifest = shipped()
            local snapshot = assert(registry.snapshot())
            for _, namespace in ipairs({"bee.driver.claude.descriptor", "bee.driver.codex.profiles"}) do
                local entries = assert(snapshot:namespace(namespace))
                test.is_true(#entries > 0, namespace)
                for _, entry in ipairs(entries) do test.is_false(protected_kernel.names(manifest, entry.id), entry.id) end
            end
        end)
        test.it("opens super edit for a governed namespace and refuses a kernel one", function()
            local manifest = shipped()
            test.is_true(protected_kernel.opened(manifest, "bee.apps.settings.app:app"))
            local workspace = string.rep("a", 32)
            test.is_false(protected_kernel.names(manifest, "bee.apps.settings.app:app"))
            test.is_false(protected_kernel.names(manifest, "bee.shell:main"))
            local opened = super_edit.enable({profiles = {}}, workspace, "node-local", {"app.tally", "bee.apps.settings.app", "bee.shell"},
                "2050-01-01T00:00:00.000Z", manifest)
            test.not_nil(opened)
            local refused, refusal = super_edit.enable({profiles = {}}, workspace, "node-local", {"bee.gov.binding"},
                "2050-01-01T00:00:00.000Z", manifest)
            test.is_nil(refused)
            test.eq(refusal, "kernel namespace is protected: bee.gov.binding")
        end)
    end)
end

return test.run_cases(define_tests)
