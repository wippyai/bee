-- MIT. The node owner: the one process that owns this node's workspaces (the
-- folders it works in), its set of desktops, its appearance and its running
-- apps. Each desktop works in one workspace; each app runs on one desktop as a
-- producer process presenting into its own viewport, started in its desktop's
-- workspace. A display shows one desktop at a time and attaches to its apps
-- one by one, owning their placement. Operations arrive only from this node's Hive supervisor,
-- which supplies the caller's authenticated PID; mounts are bound to that
-- exact PID.
local worker = require("worker")
local process = require("process")
local channel = require("channel")
local system = require("system")
local logger = require("logger")
local protocol = require("protocol")
local workspaces = require("workspaces")
local client = require("client")
local eventbus = require("events")
local broker = require("broker")
local command = require("command")
local arguments = require("arguments")
local env = require("env")
local seam = require("seam")
local part_catalog = require("part_catalog")
local part_handover = require("part_handover")
local node_state = require("node_state")
local apps = require("apps")
local desktops = require("desktops")
local attention_events = require("attention_events")
type State = node_state.State
local NAME = "bee.node"
-- Bee components announce what needs the person on this event system: a
-- request waiting for a decision, or an application the person approved.
local ATTENTION = "bee.attention"

-- idle keeps a client's owner service without serving: an in-memory client
-- displays another node and has no desktops of its own.
local idle = worker.idle

local function main(saved: unknown)
    if env.get("bee:role") == "client" then return idle() end
    local node = assert(system.node.id())
    -- Apps are linked to the owner: an owner that fails takes its apps with
    -- it, so the restarted owner reopens each kept app once. The owner traps
    -- links, so an app that fails only ends that app.
    assert(process.set_options({upgradable = true, trap_links = true}))
    local registered, register_error = process.registry.register(NAME)
    if not registered and process.registry.lookup(NAME, process.registry.LOCAL) ~= process.pid() then
        error("register node owner: " .. tostring(register_error))
    end
    if protocol.clustered() then
        local published, publish_error = process.registry.register(client.DIRECTORY .. node, process.pid(), process.registry.EVENTUAL)
        if not published and process.registry.lookup(client.DIRECTORY .. node, process.registry.EVENTUAL) ~= process.pid() then
            error("publish node owner: " .. tostring(publish_error))
        end
    end
    local folder = assert(system.process.cwd())
    local home, home_error = workspaces.follow(folder)
    if not home then error("register folder workspace: " .. tostring(home_error)) end
    local home_id = home.id
    local requests = assert(process.listen(protocol.FORWARD, {message = true}))
    -- The bee.app messages apps send their broker, one channel per topic.
    local app_inboxes: {{topic: string, inbox: channel.Channel<process.Message>}} = {}
    for _, topic in ipairs(broker.TOPICS) do
        app_inboxes[#app_inboxes + 1] = {topic = topic, inbox = assert(process.listen(topic, {message = true}))}
    end
    local events = assert(process.events())
    -- The installed apps and themes, refreshed when a registry change commits.
    local registry_changes = assert(eventbus.subscribe("registry", "registry.commit")):channel()
    local attention = assert(eventbus.subscribe(ATTENTION)):channel()
    local state = node_state.new(node, home_id)
    local instances, watchers = state.instances, state.watchers

    -- stats reports this node's runtime numbers and what it runs, for a
    -- hive view that samples it while it is open.
    local function stats(): protocol.Reply
        local memory, memory_error = system.memory.stats()
        if not memory then return protocol.fail("memory statistics: " .. tostring(memory_error)) end
        local goroutines, goroutines_error = system.runtime.goroutines()
        if not goroutines then return protocol.fail("goroutines: " .. tostring(goroutines_error)) end
        local cpu_count, cpu_error = system.runtime.cpu_count()
        if not cpu_count then return protocol.fail("cpu count: " .. tostring(cpu_error)) end
        local app_count = 0
        for _ in pairs(instances) do app_count = app_count + 1 end
        local listed = workspaces.list() or {}
        local home = workspaces.workspace(home_id)
        return protocol.ok({node = node, name = home and home.label or node, heap = memory.heap_alloc, reserved = memory.sys, gc_cycles = memory.num_gc,
            goroutines = goroutines, cpu_count = cpu_count, apps = app_count, workspaces = #listed})
    end

    -- resolve_command finds the installed app a `bee NAME` command opens and
    -- the arguments it opens with.
    local function resolve_command(name: unknown, tail: unknown, caller: string): protocol.Reply
        if type(name) ~= "string" then return protocol.fail("command needs a name") end
        local words_given = arguments.decode(tail)
        if not words_given then return protocol.fail("command arguments must be a list of words") end
        local installed: {[string]: boolean} = {}
        local desktop = watchers[caller] and workspaces.desktop(watchers[caller]) or nil
        local admitted, err = part_catalog.admitted(state.installed_apps, desktop and desktop.workspace_id or home_id)
        if not admitted then return protocol.fail(err or "application admission unavailable") end
        for _, app in ipairs(admitted) do installed[tostring(app.id)] = true end
        local launch, problem = command.resolve(name, words_given, installed)
        if not launch then return protocol.fail(problem or "Unknown Bee command: " .. name) end
        return protocol.ok({app = launch.definition_id, arguments = launch.arguments, fullscreen = launch.fullscreen})
    end

    local function handle(request: protocol.Forwarded): protocol.Reply
        local op, args = request.op, request.args
        if op == "list" then return protocol.ok(node_state.snapshot(state, request.caller)) end
        if op == "watch" then return desktops.watch(state, request.caller, args.desktop) end
        if op == "show" then return desktops.show(state, request.caller, args.desktop) end
        if op == "leave" then return desktops.leave(state, request.caller) end
        if op == "open" then return apps.open(state, args.app, args.desktop, args.args) end
        if op == "present" then return attention_events.open_requested(state, args.workspace, args.app, args.arguments, args.request) end
        if op == "attach" then return apps.attach(state, request.caller, args.id) end
        if op == "close" then return apps.close(state, args.id, args.force, args.execution_id) end
        if op == "answer" then return apps.answer(state, args) end
        if op == "command" then return resolve_command(args.name, args.arguments, request.caller) end
        if op == "stats" then return stats() end
        if op == "instances" then
            if type(args.app) ~= "string" or args.app == "" then return protocol.fail("instances needs an app") end
            return protocol.ok({instances = part_handover.app_instances(instances, args.app)})
        end
        if op == "move" then return apps.move(state, args.id, args.desktop) end
        if op == "themes" then return node_state.theme_list(state) end
        if op == "appearance" then return node_state.set_appearance(state, args) end
        if op == "workspaces" then
            local listed, err = node_state.workspace_catalog(state)
            if not listed then return protocol.fail(err or "workspaces unavailable") end
            return protocol.ok({node = node, home = home_id, workspaces = listed.workspaces, desktops = listed.desktops})
        end
        if op == "desktop_workspace" then return desktops.use_workspace(state, args.id, args.workspace) end
        if op == "workspace_add" then return desktops.add_workspace(state, args.path, args.label) end
        if op == "workspace_remove" then return desktops.remove_workspace(state, args.id) end
        if op == "desktop_create" then return desktops.create(state, args.workspace, args.title) end
        if op == "desktop_rename" then return desktops.rename(state, args.id, args.title) end
        if op == "desktop_confirmation" then return desktops.confirmation(state, args) end
        if op == "desktop_close" then
            if args.approval_id ~= nil then
                local confirmed = desktops.confirm(state, args)
                if not confirmed.ok then return confirmed end
            end
            return desktops.close(state, args.id)
        end
        return protocol.fail("unknown node operation " .. op)
    end

    if not apps.restore(state, saved) then
        local node_desktops, desktops_error = desktops.node_desktops(state)
        if not node_desktops then error("first desktop: " .. tostring(desktops_error)) end
        apps.reopen(state)
    end
    apps.update_instances(state)
    local announced, announce_error = protocol.ready(NAME)
    if not announced then logger:warn("Hive supervisor not told the node is ready", {error = announce_error}) end
    seam.call("bee.node.service.ready")
    logger:info("Node ready", {node = node, folder = folder, theme = state.current.theme.id})
    while true do
        local cases = {requests:case_receive(), events:case_receive(), registry_changes:case_receive(), attention:case_receive()}
        for _, app in ipairs(app_inboxes) do cases[#cases + 1] = app.inbox:case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then return end
        local app_topic: string? = nil
        for _, app in ipairs(app_inboxes) do
            if selected.channel == app.inbox then app_topic = app.topic end
        end
        if app_topic then
            local message = selected.value
            apps.app_message(state, app_topic, tostring(message:from()), message:payload():data())
        elseif selected.channel == registry_changes then
            node_state.refresh(state)
            apps.update_instances(state)
        elseif selected.channel == attention then
            attention_events.attend(state, selected.value)
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL then
                for _, instance in pairs(instances) do
                    apps.retire(instance.alias)
                    instance.view:close()
                end
                return
            end
            if event.kind == process.event.OUTDATED then
                process.upgrade("", node_state.handover(state))
                return
            end
            if event.kind == process.event.EXIT or event.kind == process.event.MONITOR_DOWN or event.kind == process.event.LINK_DOWN then
                local result: unknown = event.result
                local problem: string? = nil
                if type(result) == "table" and result.error ~= nil then problem = tostring(result.error) end
                apps.exited(state, tostring(event.from), problem)
            end
        else
            local message = selected.value
            local request = protocol.forwarded(tostring(message:from()), message:payload():data())
            if request then
                local handled, reply = pcall(handle, request)
                if not handled then
                    logger:error("Node operation failed", {op = request.op, error = tostring(reply)})
                    reply = protocol.fail(request.op .. " failed: " .. tostring(reply))
                end
                process.send(request.caller, request.reply_topic, reply)
            else
                logger:warn("Node ignored a request that did not come from the node supervisor", {from = tostring(message:from())})
            end
        end
    end
end

return {main = main}
