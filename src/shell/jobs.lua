-- MIT. Display attachment, command and watcher jobs.
local tty = require("tty")
local channel = require("channel")
local process = require("process")
local client = require("client")
local part_handover = require("part_handover")
local M = {}
type Result = part_handover.Result
type Binding = part_handover.Binding
function M.new(current_target: () -> string, results: channel.Channel<Result>)
    local function reconcile(id: string, problem: string?): Result
        local value = client.call(current_target(), "list", {})
        local snapshot = value and client.state(value)
        if snapshot then
            local live = false
            for _, instance in ipairs(snapshot.running) do
                if instance.id == id then live = true end
            end
            if not live then return {kind = "retired", id = id, state = snapshot} end
        end
        if problem then return {kind = "failed", id = id, problem = problem} end
        return {kind = "done"}
    end

    local function attach_job(id: string, shown: string): Result
        local attached = client.call(current_target(), "attach", {id = id})
        if not attached then return reconcile(id, "Cannot show this app.") end
        if type(attached.ref) ~= "string" then return reconcile(id, "Cannot show this app.") end
        local view = tty.attach(attached.ref)
        if not view then return reconcile(id, "Cannot show this app.") end
        local title = id
        if type(attached.title) == "string" then title = attached.title end
        return {kind = "attached", id = id, title = title, view = view, desktop = shown}
    end

    local function call_job(op: string, args: {[string]: unknown}): Result
        local _, err = client.call(current_target(), op, args)
        local id = args.id
        if type(id) == "string" and (op == "close" or op == "move" or op == "answer") then
            local problem = err and (op == "close" and "Cannot close this app."
                or op == "move" and "Cannot move this app." or "Cannot answer this app.")
            if err or op == "close" then return reconcile(id, problem) end
        end
        if err then return {kind = "failed", problem = "The request could not be completed."} end
        return {kind = "done"}
    end

    -- watch_job watches target once its owner serves. A node without a
    -- serving owner reports "away", and the display waits for it again.
    local function watch_job(node: string, requested: string, stamp: integer): Result
        local holder = process.registry.lookup(client.DIRECTORY .. node, process.registry.EVENTUAL, {timeout = client.TIMEOUT})
        if not holder then return {kind = "away", desktop = requested} end
        local bound: channel.Channel<Binding> = channel.new(1)
        results:send({kind = "following", following = tostring(holder), bound = bound, generation = stamp})
        local binding = assert((bound:receive()))
        if binding.problem then return {kind = "failed", problem = binding.problem} end
        if not binding.ok then return {kind = "away", desktop = requested} end
        local args: {[string]: unknown} = {}
        if requested ~= "" then args.desktop = requested end
        local value, watch_error = client.call(node, "watch", args)
        if not value then
            if not client.serving(node) then return {kind = "away", desktop = requested} end
            return {kind = "failed", problem = "Cannot reach " .. node .. ": " .. tostring(watch_error)}
        end
        local decoded = client.state(value)
        if not decoded then return {kind = "failed", problem = "malformed state from " .. node} end
        return {kind = "watched", state = decoded}
    end

    return {attach_job = attach_job, call_job = call_job, watch_job = watch_job}
end
return M
