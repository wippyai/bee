-- MIT. An installed application whose granted folder is missing stays out of
-- a restarted node with the reason the person reads in the Library; the node
-- boots, and the application returns once the folder is back.
local test = require("test")
local bounds = require("bounds")
local json = require("json")
local fs = require("fs")
local system = require("system")
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")
local registry = require("registry")
local harness = require("harness")
local library = require("library")
local governed = require("governed")
local test_fixtures = require("test_fixtures")
local guide = require("guide")
local workspace_applications = require("workspace_applications")
type Object = {[string]: unknown}

local OVERLAY = "grantedfolder"
local APP = "app." .. OVERLAY .. ":app"
local REASON = "folder cmd/ is missing; restore it or remove the grant"

local function entries(): {Object}
    local bytes = assert(json.encode(guide.example())):gsub("app.counter", "app." .. OVERLAY)
    local pack = assert(json.decode(bytes)) :: {Object}
    local application = assert(bounds.object((assert(bounds.object(pack[1].meta))).application))
    application.capabilities = {{capability = "workspace.files.read",
        parameters = {subpath = "cmd"}, reason = "Read the commands"}}
    return pack
end

local function rows(workspace: string)
    local listed = harness.value(harness.library(workspace, {operation = "activations"}))
    local shown = library.new(workspace)
    test.is_true(governed.apply_activations(shown.governed, assert(governed.reply({ok = true, replayed = false, value = listed}))))
    return library.rows(shown, "installed")
end

-- The person's Library on a viewport of the workspace.
type Screen = {shown: (string) -> (), press: (string, string?) -> (), close: () -> ()}
local function open_library(workspace: string): Screen
    local viewport = assert(tty.viewport({width = 150, height = 35}))
    local pid = assert(process.with_options({terminal = assert(viewport:grant())})
        :spawn_monitored("bee.apps.library.app:app", "bee:workers", {workspace = {id = workspace}}))
    local function shown(needle: string)
        local updates = assert(viewport:updates())
        local deadline = time.after("10s")
        while true do
            local snapshot = viewport:snapshot()
            local text = snapshot and table.concat(snapshot.rows, "\n") or ""
            if text:find(needle, 1, true) then return end
            local next_event = channel.select({updates:case_receive(), deadline:case_receive()})
            assert(next_event.channel ~= deadline, "Library does not show " .. needle .. ": " .. text)
        end
    end
    local function press(kind: string, value: string?)
        assert(viewport:send({type = "key", action = "press", key_type = kind, key = value or ""}))
    end
    local function close()
        assert(process.cancel(tostring(pid), "granted folder proof complete"))
        viewport:close()
    end
    return {shown = shown, press = press, close = close}
end

local function define_tests()
    test.describe("boot recovery of an application whose granted folder is missing", function()
        test.after_all(test_fixtures.registry_cleanup(true))
        test.it("boots without the application, shows why in the Library and restores it once the folder is back", function()
            -- A granted folder lies outside Bee's private state; the suites'
            -- own folders lie beneath it, so the workspace is placed in the
            -- shared folder the delivery suites use for file grants.
            local workspace, path = harness.isolated(OVERLAY, "/tmp")
            local folders = assert(fs.get("bee.tests.gov:bundle_files"))
            local directory = path:sub(#"/tmp/" + 1)
            assert(folders:mkdir(directory))
            assert(folders:mkdir(directory .. "/cmd"))
            local author = harness.author(workspace, OVERLAY)
            local before = harness.running()
            local requested = harness.value(harness.deliver(author, OVERLAY, workspace, entries(), "1"))
            test.eq(harness.settle(author, OVERLAY, workspace, requested, "1").outcome, "applied")
            harness.close_presented(before)
            local owner = assert(workspace_applications.identity(workspace, OVERLAY)).overlay_owner
            test.not_nil((registry.get("app." .. OVERLAY .. ":cmd")))

            assert(folders:remove(directory .. "/cmd"))
            local refused = harness.restart({owner})
            test.eq(#refused, 1, "the application left out is reported")
            test.contains(tostring(refused[1]), owner)
            test.contains(tostring(refused[1]), REASON)
            test.is_nil((registry.get(APP)))
            local shown = rows(workspace)
            test.eq(#shown, 1, "the Library lists the application left out")
            test.eq(shown[1].status, library.STATUS_LEFT_OUT)
            test.eq(shown[1].note, REASON)
            test.eq(#harness.restart({owner}), 1, "the application stays out while its folder is missing")

            local screen = open_library(workspace)
            local presented, problem = pcall(function()
                screen.shown("Left out")
                screen.press("runes", "d")
                screen.shown(REASON)
                screen.shown("Enter Recover")
            end)
            screen.close()
            assert(presented, tostring(problem))
            assert(folders:mkdir(directory .. "/cmd"))
            harness.value(harness.library(workspace, {operation = "recover", source_node = assert(system.node.id()),
                source_workspace = OVERLAY, receipt_key = OVERLAY .. "-recover"}))
            test.not_nil((registry.get(APP)), "Recover restores the application once its folder is back")
            test.eq(rows(workspace)[1].status, library.STATUS_INSTALLED)
            test.eq(#harness.restart({owner}), 0, "a restart restores the application")
            test.not_nil((registry.get(APP)))

            harness.value(harness.library(workspace, {operation = "uninstall", source_workspace = OVERLAY,
                receipt_key = OVERLAY .. "-remove"}))
            harness.close_presented(before)
            assert(folders:remove(directory .. "/cmd"))
            assert(folders:remove(directory))
        end)
    end)
end

return test.run_cases(define_tests)
