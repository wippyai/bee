-- MIT. A session's terminal viewer holds only a recipient-bound mount.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")
local logger = require("logger")
local waiting = require("waiting")
local presentation = require("presentation")
local bounds = require("bounds")
local client = require("client")
local input_event = require("input_event")
local M = {}
type Channel = channel.Channel
function M.run(launch: client.Launch, session: string, input: tty.EventChannel,
    lifecycle: Channel<process.Event>, closes: Channel<process.Message>, thread_id: string?): (boolean, string?)
    local raw = presentation.attach({session = session})
    local err: string? = nil
    local reply = bounds.object(raw)
    local value = reply and bounds.object(reply.value)
    local mount = value and bounds.id(value.mount)
    if err or not reply or reply.ok ~= true or not mount then
        local fault = reply and bounds.object(reply.error)
        return false, tostring(err or (fault and fault.message) or "terminal attachment unavailable")
    end
    local view, attach_error = tty.attach(mount)
    if not view then return false, tostring(attach_error) end
    local updates = assert(view:updates())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    assert(view:resize(width, height))
    local review_ticks = thread_id and assert(time.ticker("1s")) or nil
    local reviews = review_ticks and review_ticks:channel()
    local review_key = ""
    local function publish_review()
        if not thread_id then return end
        local review, problem = waiting.read(thread_id)
        if problem then logger:warn("Waiting request lookup failed", {error = problem}); return end
        local key = review and (review.approval_id .. review.title) or ""
        if key ~= review_key then
            assert(client.review(launch, review))
            review_key = key
        end
    end
    publish_review()
    local closing = false
    while true do
        local snapshot, snapshot_error = view:snapshot()
        if snapshot_error then err = tostring(snapshot_error); break end
        if snapshot then assert(output:present(snapshot.rows, {cursor = snapshot.cursor})) end
        local cases = {input:case_receive(), lifecycle:case_receive(), closes:case_receive(), updates:case_receive()}
        if reviews then cases[#cases + 1] = reviews:case_receive() end
        local event = channel.select(cases)
        if not event.ok then break end
        if reviews and event.channel == reviews then publish_review()
        elseif event.channel == lifecycle and event.value.kind == process.event.CANCEL then closing = true; break
        elseif event.channel == closes then
            local close = client.close_request(launch, tostring(event.value:from()), event.value:payload():data())
            if close then client.close_reply(launch, close.request_id, {action = "accept"}); closing = true; break end
        elseif event.channel == input then
            local data = input_event.decode(event.value)
            if data then
                if data.type == "close" then closing = true; break
                elseif data.type == "resize" or data.type == "start" then
                    assert(view:resize(data.width, data.height))
                else
                    local sent, send_error = view:send(data)
                    if not sent then err = tostring(send_error or "terminal input failed"); break end
                end
            end
        end
    end
    if review_ticks then review_ticks:stop() end
    client.review(launch, nil)
    output:close()
    view:close()
    presentation.attach({session = session, detach = true})
    return closing, err and tostring(err) or nil
end
return M
