-- MIT. The public application test facade. It decodes the request, takes the
-- caller's workspace and actor from the authenticated context, lists the
-- overlays the caller owns through the overlay facade, and hands both to the
-- node's test runner, which admits only applications delivered from them.
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local bounds = require("bounds")
local tests = require("tests")

local OVERLAYS = "bee.gov.binding:overlay_call"

-- owned lists the overlay ids the caller owns.
local function owned(): ({string}?, tests.Reply?)
    local raw, call_error = funcs.new():call(OVERLAYS, {operation = "list"})
    if call_error then return nil, tests.fail("UNAVAILABLE", "overlay listing: " .. tostring(call_error)) end
    local reply = bounds.object(raw)
    local value = reply and reply.ok == true and bounds.object(reply.value) or nil
    local rows = value and type(value.overlays) == "table" and value.overlays :: {unknown} or nil
    if not rows then return nil, tests.fail("DENIED", "the caller's overlays cannot be listed") end
    local ids: {string} = {}
    for _, row in ipairs(rows) do
        local overlay = bounds.object(row)
        local id = overlay and bounds.id(overlay.overlay_id)
        if id then ids[#ids + 1] = id end
    end
    return ids, nil
end

local function handle(raw: unknown): tests.Reply
    local request, invalid = tests.decode(raw)
    if not request then return tests.fail("INVALID", invalid or "invalid request") end
    local actor = security.actor()
    local metadata = actor and bounds.object(actor:meta()) or nil
    local workspace = metadata and bounds.id(metadata.workspace_id) or nil
    if not actor or not workspace then return tests.fail("DENIED", "tests need an authenticated workspace caller") end
    local overlays: {string} = {}
    if request.operation ~= "status" then
        local listed, fault = owned()
        if not listed then return fault or tests.fail("DENIED", "the caller's overlays cannot be listed") end
        overlays = listed
    end
    local pid = process.registry.lookup(tests.NAME)
    if not pid then return tests.fail("UNAVAILABLE", "the node's test runner is not running") end
    local reply_topic = "bee.node.tests.reply." .. tostring(uuid.v7())
    local replies = assert(process.listen(reply_topic, {message = true}))
    local sent, send_error = process.send(pid, tests.REQUEST, {operation = request.operation, application = request.application,
        filter = request.filter, run_id = request.run_id, workspace_id = workspace, actor_id = actor:id(),
        overlays = overlays, reply_topic = reply_topic})
    if not sent then
        process.unlisten(replies)
        return tests.fail("UNAVAILABLE", "the test runner did not take the request: " .. tostring(send_error))
    end
    local deadline = time.after(tests.ANSWER)
    local selected = channel.select({replies:case_receive(), deadline:case_receive()})
    process.unlisten(replies)
    if not selected.ok or selected.channel == deadline then
        return tests.fail("UNAVAILABLE", "the test runner did not answer within " .. tests.ANSWER)
    end
    local answer = bounds.object(selected.value:payload():data())
    if not answer or type(answer.ok) ~= "boolean" then return tests.fail("UNAVAILABLE", "the test runner answered with an invalid reply") end
    if answer.ok then return tests.succeed(answer.value) end
    local fault = bounds.object(answer.error)
    return tests.fail(fault and bounds.text(fault.code, 64) or "FAILED", fault and bounds.text(fault.message, 4096) or "the test run failed")
end

return {handle = handle}
