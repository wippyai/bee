-- MIT. A test app: presents the theme and the label it was opened with, the
-- workspace it runs in, the principal it runs as and whether its launch is a
-- bee.app launch, which owner authority it holds, the workspace its host
-- context names, and the appearance changes it receives, until cancelled.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local appearance = require("appearance")
local security = require("security")
local app = require("app")
local ctx = require("ctx")

local function main(options: unknown)
    local changes = assert(process.listen(appearance.TOPIC, {message = true}))
    local lifecycle = assert(process.events())
    assert(tty.start())
    local surface = assert(tty.surface({}))
    local label, workspace = "", ""
    if type(options) == "table" and type(options.args) == "table" and type(options.args.label) == "string" then
        label = options.args.label
    end
    if type(options) == "table" and type(options.workspace) == "table" and type(options.workspace.path) == "string" then
        workspace = options.workspace.path
    end
    local actor = security.actor()
    local principal = actor and actor:id() or "none"
    local meta: unknown = actor and actor:meta() or nil
    local actor_workspace = type(meta) == "table" and type(meta.workspace_id) == "string" and meta.workspace_id or "none"
    local launch = app.launch(options)
    local launched = launch and ("launch " .. launch.instance_id) or "launch none"
    local held: {string} = {}
    for _, check in ipairs({{"db.get", "bee:db"}, {"process.spawn", "bee.node.service:owner"},
        {"process.security", "security"}, {"registry.apply", "registry"},
        {"security.scope.create", "with"}, {"bee.tests.probe", "admitted"}}) do
        if security.can(check[1], check[2]) then held[#held + 1] = check[1] end
    end
    local authority = #held > 0 and table.concat(held, " ") or "none"
    local kind, of, instance = principal:match("^(bee%.application):([^:]+):(.+)$")
    local function present(theme: string)
        surface:present({"theme " .. theme, "label " .. label, "workspace " .. workspace,
            "actor " .. (kind or principal), "of " .. (of or "none"), "instance " .. (instance or "none"),
            "acts for " .. actor_workspace, launched, "authority " .. authority,
            "args " .. (launch and table.concat(launch.arguments, " ") or ""),
            "context " .. tostring(ctx.get("bee.workspace_id"))})
    end
    present(appearance.chosen(options).theme.id)
    local controller = type(options) == "table" and type(options.args) == "table" and options.args.exit_controller or nil
    local release = type(controller) == "string" and assert(process.listen("bee.test.probe.exit", {message = true})) or nil
    while true do
        local selected = channel.select({changes:case_receive(), lifecycle:case_receive()})
        if not selected.ok then break end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then
                if release and type(controller) == "string" then
                    assert(process.send(controller, "bee.test.probe.stopping", {}))
                    local message = assert((release:receive()))
                    assert(tostring(message:from()) == controller)
                    process.unlisten(release)
                end
                break
            end
        else
            present(appearance.chosen(selected.value:payload():data()).theme.id)
        end
    end
    surface:close()
    tty.stop()
end

return {main = main}
