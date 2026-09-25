-- MIT. Asynchronous viewport delivery, bounded operation queues and status.
--
-- Owner Isolation & Lifecycle:
-- In Bee architecture, each presenter runs as an isolated process actor.
-- Module-level state (entries, live_count, allocated_count, aggregate_bytes)
-- is strictly actor-local to the running presenter instance and never shared
-- across actor or process boundaries.
local tty = require("tty")

type Cursor = {
    x: integer,
    y: integer,
    visible: boolean,
}

type Content = {
    rows: {string},
    cursor: Cursor?,
}

type ResizeOp = {
    kind: "resize",
    width: integer,
    height: integer,
    bytes: integer,
}

type InputOp = {
    kind: "input",
    event: tty.InputEvent,
    bytes: integer,
}

type Op = ResizeOp | InputOp

type FailureNotification = {
    id: string,
    error: string,
}

type Entry = {
    id: string,
    mount: string,
    mount_generation: integer,
    observer: boolean,
    view: tty.Viewport?,
    retired: boolean,
    failed: boolean,
    error: string,
    queue: {Op},
    queued_bytes: integer,
    worker_active: boolean,
    cleanup_active: boolean,
    released: boolean,
    in_flight: Op?,
    requested_width: integer,
    requested_height: integer,
    last_content: Content?,
    last_revision: integer,
}

local MAX_LIVE_ATTACHMENTS: integer = 128
local MAX_ALLOCATED_ENTRIES: integer = 256
local MAX_PENDING_OPS: integer = 256
local MAX_VIEW_BYTES: integer = 1024 * 1024
local MAX_AGGREGATE_BYTES: integer = 4 * 1024 * 1024
local MAX_NOTIFICATIONS: integer = 16

local entries: {[string]: Entry} = {}
local live_count: integer = 0
local allocated_count: integer = 0
local aggregate_bytes: integer = 0
local is_shutdown: boolean = false
local completion_dirty: boolean = false
local failure_notifications: {FailureNotification} = {}
local next_mount_generation: integer = 0

local M = {}

local function push_failure(id: string, err: string)
    if #failure_notifications >= MAX_NOTIFICATIONS then
        table.remove(failure_notifications, 1)
    end
    table.insert(failure_notifications, {id = id, error = err})
end

local function set_worker_active(entry: Entry, active: boolean)
    entry.worker_active = active
end

local function set_cleanup_active(entry: Entry, active: boolean)
    entry.cleanup_active = active
end

local function check_release(entry: Entry)
    if entry.retired and not entry.worker_active and not entry.cleanup_active and not entry.released then
        entry.released = true
        allocated_count = allocated_count - 1
    end
end

local function start_cleanup(entry: Entry, view: tty.Viewport)
    set_cleanup_active(entry, true)
    coroutine.spawn(function()
        pcall(function() view:close() end)
        set_cleanup_active(entry, false)
        check_release(entry)
    end)
end

local function deduct_in_flight(entry: Entry)
    local op = entry.in_flight
    if op then
        entry.queued_bytes = entry.queued_bytes - op.bytes
        aggregate_bytes = aggregate_bytes - op.bytes
        entry.in_flight = nil
    end
end

local function clear_unstarted_queue(entry: Entry): integer
    local dropped = #entry.queue
    for _, op in ipairs(entry.queue) do
        entry.queued_bytes = entry.queued_bytes - op.bytes
        aggregate_bytes = aggregate_bytes - op.bytes
    end
    entry.queue = {}
    return dropped
end

local function fail_entry(entry: Entry, in_flight_err: string)
    if entry.failed then return end
    entry.failed = true
    local unstarted = clear_unstarted_queue(entry)
    local msg = in_flight_err .. " (in-flight outcome unknown; " .. unstarted .. " queued unstarted ops not sent)"
    entry.error = msg
    push_failure(entry.id, msg)
    completion_dirty = true
end

local function fail_entry_snapshot(entry: Entry, err: string)
    if entry.failed then return end
    entry.failed = true
    local unstarted = clear_unstarted_queue(entry)
    local msg = err ~= "" and err or "Viewport snapshot failed"
    if unstarted > 0 then
        msg = msg .. " (" .. unstarted .. " queued unstarted ops not sent)"
    end
    entry.error = msg
    push_failure(entry.id, msg)
    completion_dirty = true
end

local function retire_entry(entry: Entry)
    if entry.retired then return end
    entry.retired = true
    live_count = live_count - 1
    clear_unstarted_queue(entry)
    if entry.view then
        local view = entry.view
        entry.view = nil
        start_cleanup(entry, view)
    end
    check_release(entry)
end

local function calculate_event_bytes(event: tty.InputEvent): integer
    local base = 32
    if event.type == "paste" then
        return base + #(event.text or "")
    elseif event.type == "key" then
        return base + #(event.key or "") + #(event.key_type or "")
    elseif event.type == "mouse" then
        return base + #(event.button or "")
    end
    return base
end

local function run_worker(entry: Entry)
    while not entry.retired and not entry.failed do
        if #entry.queue == 0 then
            break
        end
        local op = table.remove(entry.queue, 1)
        if not op then
            break
        end
        entry.in_flight = op

        local view = entry.view
        if not view then
            deduct_in_flight(entry)
            break
        end

        if op.kind == "resize" then
            local target_w = op.width
            local target_h = op.height
            local ok, err = view:resize(target_w, target_h)
            deduct_in_flight(entry)
            if entry.retired then
                break
            end
            if ok then
                local snapshot, snap_err = view:snapshot()
                if snapshot then
                    entry.last_revision = snapshot.revision
                    local matches = (snapshot.width == target_w and snapshot.height == target_h)
                    local cur: Cursor? = nil
                    if matches and snapshot.cursor and snapshot.cursor.visible then
                        cur = {x = snapshot.cursor.x, y = snapshot.cursor.y, visible = true}
                    end
                    if matches or not entry.last_content then
                        entry.last_content = {rows = snapshot.rows, cursor = cur}
                    else
                        entry.last_content = {rows = entry.last_content.rows, cursor = nil}
                    end
                elseif snap_err then
                    fail_entry_snapshot(entry, tostring(snap_err))
                    break
                end
                completion_dirty = true
            else
                fail_entry(entry, tostring(err or "Resize failed"))
                break
            end
        elseif op.kind == "input" then
            local ok, err = view:send(op.event)
            deduct_in_flight(entry)
            if entry.retired then
                break
            end
            if not ok then
                fail_entry(entry, tostring(err or "Input delivery failed"))
                break
            end
        end
    end
    set_worker_active(entry, false)
    check_release(entry)
end

local function spawn_worker(entry: Entry)
    set_worker_active(entry, true)
    coroutine.spawn(function()
        run_worker(entry)
    end)
end

function M.attach(id: string, mount: string, observer: boolean?): (boolean, string?)
    if is_shutdown then
        return false, "Delivery system shut down"
    end
    if id == "" or mount == "" then
        return false, "Invalid attachment arguments"
    end

    local existing: Entry? = entries[id]
    -- Reopening a singleton can return the same live mount. Closing the old
    -- wrapper would invalidate the native capability we are about to reuse.
    if existing and existing.mount == mount then
        if existing.observer ~= (observer == true) then return false, "Attachment mode changed without a new grant" end
        if existing.failed then return false, existing.error end
        return true, nil
    end
    local will_increase_live = (existing == nil)
    if will_increase_live and live_count >= MAX_LIVE_ATTACHMENTS then
        return false, "Attachment limit reached (" .. MAX_LIVE_ATTACHMENTS .. ")"
    end
    if allocated_count >= MAX_ALLOCATED_ENTRIES then
        return false, "Total allocated entry limit reached (" .. MAX_ALLOCATED_ENTRIES .. ")"
    end

    if existing then
        entries[id] = nil
        retire_entry(existing)
    end

    live_count = live_count + 1
    allocated_count = allocated_count + 1
    next_mount_generation = next_mount_generation + 1

    local entry: Entry = {
        id = id,
        mount = mount,
        mount_generation = next_mount_generation,
        observer = observer == true,
        view = nil,
        retired = false,
        failed = false,
        error = "",
        queue = {},
        queued_bytes = 0,
        worker_active = true,
        cleanup_active = false,
        released = false,
        in_flight = nil,
        requested_width = 0,
        requested_height = 0,
        last_content = nil,
        last_revision = -1,
    }

    entries[id] = entry

    coroutine.spawn(function()
        local view, err = tty.attach(mount)
        if entry.retired then
            if view then
                start_cleanup(entry, view)
            end
            set_worker_active(entry, false)
            check_release(entry)
            return
        end
        if not view then
            entry.failed = true
            local unstarted = clear_unstarted_queue(entry)
            local msg = tostring(err or "Attach failed")
            if unstarted > 0 then
                msg = msg .. " (" .. unstarted .. " queued unstarted ops not sent)"
            end
            entry.error = msg
            push_failure(entry.id, msg)
            set_worker_active(entry, false)
            completion_dirty = true
            check_release(entry)
            return
        end
        entry.view = view
        completion_dirty = true
        run_worker(entry)
    end)

    return true, nil
end

function M.send(id: string, event: tty.InputEvent): (boolean, string?)
    if is_shutdown then
        return false, "Delivery system shut down"
    end
    local entry: Entry? = entries[id]
    if not entry or entry.retired then
        return false, "Attachment not found"
    end
    if entry.observer then return false, "View is read-only" end
    if entry.failed then
        return false, entry.error ~= "" and entry.error or "Attachment failed"
    end

    local bytes = calculate_event_bytes(event)
    if bytes > MAX_VIEW_BYTES then
        return false, "Input event exceeds per-view memory limit (1MiB)"
    end
    local pending_ops = #entry.queue + (entry.in_flight ~= nil and 1 or 0)
    if pending_ops >= MAX_PENDING_OPS then
        return false, "Per-view queue full (" .. MAX_PENDING_OPS .. " ops)"
    end
    if entry.queued_bytes + bytes > MAX_VIEW_BYTES then
        return false, "Per-view input queue limit exceeded (1MiB)"
    end
    if aggregate_bytes + bytes > MAX_AGGREGATE_BYTES then
        return false, "Presenter aggregate input queue limit exceeded (4MiB)"
    end

    local op: InputOp = {
        kind = "input",
        event = event,
        bytes = bytes,
    }

    table.insert(entry.queue, op)
    entry.queued_bytes = entry.queued_bytes + bytes
    aggregate_bytes = aggregate_bytes + bytes

    if not entry.worker_active and entry.view ~= nil and not entry.retired and not entry.failed then
        spawn_worker(entry)
    end

    return true, nil
end

function M.resize(id: string, width: integer, height: integer): (boolean, string?)
    if is_shutdown then
        return false, "Delivery system shut down"
    end
    local entry: Entry? = entries[id]
    if not entry or entry.retired then
        return false, "Attachment not found"
    end
    if entry.observer then return false, "View is read-only" end
    if entry.failed then
        return false, entry.error ~= "" and entry.error or "Attachment failed"
    end

    if width <= 0 or height <= 0 then
        return false, "Invalid resize dimensions"
    end

    if entry.requested_width == width and entry.requested_height == height then
        return true, nil
    end

    -- Only coalesce adjacent unsent resize at the tail of the queue
    local last_op: Op? = entry.queue[#entry.queue]
    if last_op and last_op.kind == "resize" then
        last_op.width = width
        last_op.height = height
        entry.requested_width = width
        entry.requested_height = height
        return true, nil
    end

    local pending_ops = #entry.queue + (entry.in_flight ~= nil and 1 or 0)
    if pending_ops >= MAX_PENDING_OPS then
        return false, "Per-view queue full (" .. MAX_PENDING_OPS .. " ops)"
    end

    local bytes: integer = 32
    if entry.queued_bytes + bytes > MAX_VIEW_BYTES then
        return false, "Per-view input queue limit exceeded (1MiB)"
    end
    if aggregate_bytes + bytes > MAX_AGGREGATE_BYTES then
        return false, "Presenter aggregate input queue limit exceeded (4MiB)"
    end

    local op: ResizeOp = {
        kind = "resize",
        width = width,
        height = height,
        bytes = bytes,
    }

    table.insert(entry.queue, op)
    entry.queued_bytes = entry.queued_bytes + bytes
    aggregate_bytes = aggregate_bytes + bytes
    entry.requested_width = width
    entry.requested_height = height

    if not entry.worker_active and entry.view ~= nil and not entry.retired and not entry.failed then
        spawn_worker(entry)
    end

    return true, nil
end

function M.content(id: string, width: integer, height: integer): (Content?, string?)
    local entry: Entry? = entries[id]
    if not entry or entry.retired then
        return nil, "Attachment not found"
    end

    if entry.failed then
        if entry.last_content then
            return {rows = entry.last_content.rows, cursor = nil}, entry.error
        end
        return nil, entry.error
    end

    if not entry.view then
        return nil, "Attaching"
    end

    local snapshot, err = entry.view:snapshot()
    if not snapshot then
        fail_entry_snapshot(entry, tostring(err or "Viewport snapshot failed"))
        if entry.last_content then
            return {rows = entry.last_content.rows, cursor = nil}, entry.error
        end
        return nil, entry.error
    end

    entry.last_revision = snapshot.revision

    -- Observers follow the producer dimensions; only its controller can resize.
    -- The presenter clips these fresh rows to its local window.
    if entry.observer or (snapshot.width == width and snapshot.height == height) then
        local cur: Cursor? = nil
        if not entry.observer and snapshot.cursor and snapshot.cursor.visible then
            cur = {x = snapshot.cursor.x, y = snapshot.cursor.y, visible = true}
        end
        entry.last_content = {rows = snapshot.rows, cursor = cur}
        return entry.last_content, nil
    end

    -- Snapshot dimensions do not match committed/requested size yet.
    -- Retain previous rows unchanged, hide cursor.
    if entry.last_content then
        return {rows = entry.last_content.rows, cursor = nil}, nil
    end

    -- No previous content exists yet; use current snapshot rows as initial placeholder with hidden cursor.
    entry.last_content = {rows = snapshot.rows, cursor = nil}
    return entry.last_content, nil
end

function M.observing(id: string): boolean
    local entry = entries[id]
    return entry ~= nil and entry.observer
end

function M.has(id: string): boolean
    local entry: Entry? = entries[id]
    return entry ~= nil and not entry.retired
end

-- The presenter uses this read-only identity to invalidate local snapshots
-- when a view is detached and attached again under the same window ID.
function M.attachment(id: string): {mount: string, generation: integer}?
    local entry: Entry? = entries[id]
    if not entry or entry.retired then return nil end
    return {mount = entry.mount, generation = entry.mount_generation}
end

function M.is_failed(id: string): boolean
    local entry: Entry? = entries[id]
    return entry ~= nil and entry.failed
end

function M.poll_failure(): FailureNotification?
    while #failure_notifications > 0 do
        local failure: FailureNotification? = table.remove(failure_notifications, 1)
        if failure then
            local current = entries[failure.id]
            if current and current.failed and current.error == failure.error then return failure end
        end
    end
    return nil
end

function M.requested_width(id: string): integer
    local entry: Entry? = entries[id]
    return (entry and entry.requested_width) or 0
end

function M.requested_height(id: string): integer
    local entry: Entry? = entries[id]
    return (entry and entry.requested_height) or 0
end

function M.close(id: string)
    local entry: Entry? = entries[id]
    if not entry then return end
    entries[id] = nil
    retire_entry(entry)
end

function M.shutdown()
    is_shutdown = true
    local ids: {string} = {}
    for id in pairs(entries) do
        table.insert(ids, id)
    end
    for _, id in ipairs(ids) do
        local entry = entries[id]
        if entry then
            entries[id] = nil
            retire_entry(entry)
        end
    end
end

function M.poll(visible_ids: {string}): boolean
    local dirty = completion_dirty
    completion_dirty = false
    for _, id in ipairs(visible_ids) do
        local entry: Entry? = entries[id]
        if entry and entry.view and not entry.retired and not entry.failed then
            local snapshot, err = entry.view:snapshot()
            if not snapshot then
                fail_entry_snapshot(entry, tostring(err or "Viewport snapshot failed"))
                dirty = true
            else
                if snapshot.revision ~= entry.last_revision then
                    entry.last_revision = snapshot.revision
                    local matches = (snapshot.width == entry.requested_width and snapshot.height == entry.requested_height)
                    local cur: Cursor? = nil
                    if matches and snapshot.cursor and snapshot.cursor.visible then
                        cur = {x = snapshot.cursor.x, y = snapshot.cursor.y, visible = true}
                    end
                    if matches or not entry.last_content then
                        entry.last_content = {rows = snapshot.rows, cursor = cur}
                    else
                        entry.last_content = {rows = entry.last_content.rows, cursor = nil}
                    end
                    dirty = true
                end
            end
        end
    end
    return dirty
end

return M
