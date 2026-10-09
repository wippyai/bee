-- SPDX-License-Identifier: MIT
local channel = require("channel")
local time = require("time")
local logger = require("logger")
local worker = require("worker")
local M = {}
type Task = {name: string, pass: () -> boolean, active: boolean, pending: boolean,
    retry_ms: integer, due: integer?, completed: channel.Channel<boolean>}
M.Task = Task
local function now(): integer return math.floor(time.now():unix_nano() / 1000000) end
function M.new(name: string, pass: () -> boolean): Task
    return {name = name, pass = pass, active = false, pending = true, retry_ms = worker.RETRY_FIRST_MS,
        due = nil, completed = channel.new(1)}
end
function M.wake(task: Task)
    task.pending, task.due = true, nil
end
function M.defer(task: Task, milliseconds: integer)
    task.pending, task.due = true, now() + milliseconds
end
function M.advance(task: Task)
    if task.active or not task.pending or (task.due and task.due > now()) then return end
    task.active, task.pending, task.due = true, false, nil
    coroutine.spawn(function()
        local called, quiet = pcall(task.pass)
        if not called then logger:error("Owner task failed", {task = task.name, cause = tostring(quiet)}) end
        task.completed:send(called and quiet == true)
    end)
end
function M.finish(task: Task, quiet: boolean)
    task.active = false
    if quiet then task.retry_ms = worker.RETRY_FIRST_MS
    else
        M.defer(task, task.retry_ms)
        task.retry_ms = math.min(task.retry_ms * 2, worker.RETRY_LAST_MS)
    end
end
function M.deadline(task: Task): channel.Channel<unknown>?
    if task.due then return time.after(tostring(math.max(1, task.due - now())) .. "ms") end
    return nil
end
function M.quiet(task: Task): boolean
    return not task.active and not task.pending and task.due == nil
end
return M
