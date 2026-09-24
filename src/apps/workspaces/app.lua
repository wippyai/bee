-- MIT. The Workspaces viewer: pages and searches the node workspace catalog,
-- shows what the selected workspace holds, archives and restores it, and can
-- serve it (hold a host lease) while the viewer stays open. It reads one page
-- at a time and never the whole catalog. Every owner answers under this
-- process's actor and its host-selected policies.
local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")
local uuid = require("uuid")
local funcs = require("funcs")
local appearance = require("appearance")
local frame = require("frame")
local caller = require("caller")
local leases = require("leases")
local model = require("model")
local view = require("view")

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local broker = launch.broker_pid
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local owner = caller.new(function(target: string, request: unknown): (unknown, string?)
        local reply, err = funcs.new():call(target, request)
        if err then return nil, tostring(err) end
        return reply, nil
    end)
    local state: model.State = model.new()
    local lease: leases.Lease? = nil
    local offset, capacity = 0, 0
    local hits: {frame.Hit} = {}
    local running, dirty, announced = true, true, false

    local function ask(intent: model.Intent): caller.Reply
        return owner:invoke(intent.target, intent.request) or caller.unknown()
    end
    local function standard(): boolean
        local size = frame.size(width, height)
        return size == "standard" or size == "wide"
    end
    local function inspect()
        local intent = model.inspect_intent(state)
        if not intent then model.forget_detail(state); return end
        local selected = state.selected
        model.apply_inspect(state, selected, ask(intent))
        local threads = model.threads_intent(state)
        if threads then model.apply_threads(state, selected, ask(threads)) end
    end
    local function page()
        model.apply_page(state, ask(model.listing(state)))
        offset = 0
        if standard() or state.showing then inspect() end
        dirty = true
    end
    local function selected_changed()
        if standard() or state.showing then inspect() end
        dirty = true
    end
    local function move(step: integer)
        local moved = model.move(state, step)
        if moved == "page" then page() elseif moved == "select" then selected_changed() end
    end
    local function release()
        if lease then leases.release(lease) end
        lease = nil
        model.serve(state, nil)
    end
    local function serve()
        if lease then
            release()
            model.say(state, "Released the workspace host")
            if standard() or state.showing then inspect() end
            return
        end
        local selected = model.selected(state)
        if not selected or state.tab == "archived" then return end
        local held, refusal = leases.acquire(selected.workspace_id, "30s")
        if not held then
            model.say(state, "Could not serve " .. model.label(state, selected.workspace_id) .. ": " .. tostring(refusal))
            return
        end
        lease = held
        model.serve(state, selected.workspace_id)
        model.say(state, held.managed and "Serving " .. model.label(state, selected.workspace_id) .. " while this view is open"
            or model.label(state, selected.workspace_id) .. " is already served by its own host")
        inspect()
    end
    local function change()
        local intent = model.change_intent(state)
        if not intent then return end
        if state.tab == "active" and not state.confirming then model.confirm(state, true); return end
        if lease and state.served == state.selected then release() end
        model.apply_change(state, ask(intent))
        if standard() then inspect() end
    end
    local function open()
        if state.selected == "" then return end
        if not standard() then model.show(state, true) end
        inspect()
    end
    local function back(): boolean
        if state.confirming then model.confirm(state, false); return true end
        if state.showing then model.show(state, false); return true end
        return false
    end
    local function act(kind: string, key: string)
        if kind == "open" then if state.showing then back() else open() end
        elseif kind == "search" or kind == "field" then model.edit(state, true)
        elseif kind == "refresh" then page()
        elseif kind == "serve" then serve()
        elseif kind == "change" then change()
        elseif kind == "active" or kind == "archived" then model.switch(state, kind); page()
        elseif kind == "workspace" then model.select(state, key); selected_changed() end
        dirty = true
    end

    page()
    if broker then process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"}) end
    while running do
        if dirty then
            local drawn = view.draw(width, height, preferences, state, offset)
            hits, capacity, offset = drawn.hits, drawn.capacity, drawn.offset
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch); announced = true end
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), states:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then break end
        elseif event.channel == states then
            local message = event.value
            if broker and message:from() == broker then
                local decoded = appearance.decode(message:payload():data())
                if decoded then preferences = decoded; dirty = true end
            end
        else
            local data = event.value
            if data.type == "close" then running = false
            elseif data.type == "resize" then
                width, height = data.width, data.height
                if standard() and not state.detail then inspect() end
                dirty = true
            elseif data.type == "key" and data.action ~= "release" then
                local key = data.key_type
                dirty = true
                if state.editing then
                    if key == "enter" then model.submit(state); page()
                    elseif key == "esc" or key == "escape" then model.edit(state, false)
                    elseif key == "backspace" then model.erase(state)
                    elseif type(data.key) == "string" and data.key ~= "" then model.type_text(state, data.key) end
                elseif state.confirming then
                    if key == "enter" then change()
                    elseif key == "esc" or key == "escape" then model.confirm(state, false) end
                elseif key == "up" then move(-1)
                elseif key == "down" then move(1)
                elseif key == "pgdown" then if model.forward(state) then page() end
                elseif key == "pgup" then if model.backward(state) then page() end
                elseif key == "enter" then open()
                elseif key == "tab" then model.switch(state, state.tab == "active" and "archived" or "active"); page()
                elseif key == "esc" or key == "escape" then if not back() then running = false end
                elseif data.key == "/" then model.edit(state, true)
                elseif data.key == "r" then page()
                elseif data.key == "s" then serve()
                elseif data.key == "a" then change() end
            elseif data.type == "mouse" then
                local x, y = math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1)
                if data.action == "wheel" then move((data.button == "wheel_up" or data.button == "up") and -1 or 1)
                elseif data.action == "press" and data.button == "left" then
                    local hit = frame.hit(hits, x, y)
                    if hit then act(hit.kind, hit.key) end
                end
            end
        end
    end
    release()
    process.unlisten(states)
    output:close(); tty.stop()
end

return {main = main}
