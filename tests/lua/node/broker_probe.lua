-- MIT. A test app on the bee.app SDK: it announces itself ready to negotiate
-- its close and titles itself from its launch; it answers a close as its
-- first argument says (accept, cancel or confirm), asks the query its second
-- argument names, checkpoints its third, navigates to itself when its fourth
-- says so, and shows on its screen what it got
-- back and any navigation it receives.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local client = require("app")

local function main(options: unknown)
    local launch = assert(client.launch(options))
    local closes = assert(process.listen("bee.app.close", {message = true}))
    local close_results = assert(process.listen("bee.app.close.result", {message = true}))
    local answers = assert(process.listen("bee.app.query.result", {message = true}))
    local checkpoints = assert(process.listen("bee.app.checkpoint_result", {message = true}))
    local navigations = assert(process.listen("bee.app.navigate", {message = true}))
    local close_seen = launch.arguments[5] == "observe-close" and assert(process.listen("bee.tests.close_seen", {message = true})) or nil
    local pending_close: string? = nil
    local lifecycle = assert(process.events())
    assert(tty.start())
    local surface = assert(tty.surface({}))
    local close_action = launch.arguments[1] or "accept"
    local lines = {"resume " .. (launch.resume_state ~= "" and launch.resume_state or "none"), "answer none",
        "checkpoint none", "navigated none", "close none"}
    local function present() surface:present(lines) end
    present()
    client.ready(launch, {negotiate_close = true})
    client.title(launch, "Broker probe " .. close_action)
    if launch.arguments[2] and launch.arguments[2] ~= "" then
        assert(client.query(launch, {kind = "text", title = launch.arguments[2], accept = "Send", initial = "draft"}))
    end
    if launch.arguments[3] and launch.arguments[3] ~= "" then assert(client.checkpoint(launch, launch.arguments[3])) end
    if launch.arguments[4] == "navigate" then assert(client.navigate(launch, launch.definition_id, {"to", "here"})) end
    while true do
        local cases = {closes:case_receive(), close_results:case_receive(), answers:case_receive(),
            checkpoints:case_receive(), navigations:case_receive(), lifecycle:case_receive()}
        if close_seen then cases[#cases + 1] = close_seen:case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then break end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then break end
        else
            local from, data = tostring(selected.value:from()), selected.value:payload():data()
            if selected.channel == closes then
                local request = client.close_request(launch, from, data)
                if request then
                    lines[5] = "close asked"
                    local action: "accept" | "cancel" | "confirm" = "accept"
                    if close_action == "cancel" then action = "cancel" elseif close_action == "confirm" then action = "confirm" end
                    if close_seen and action == "accept" then pending_close = request.request_id
                    else client.close_reply(launch, request.request_id, {action = action,
                        title = "Close probe?", message = "It has work", accept = "Close"}) end
                end
            elseif selected.channel == close_seen and pending_close then
                assert(client.close_reply(launch, pending_close, {action = "accept"}))
                pending_close = nil
            elseif selected.channel == close_results then
                if client.close_result(launch, from, data) then lines[5] = "close cancelled" end
            elseif selected.channel == answers then
                local result = client.query_result(launch, from, data)
                if result then lines[2] = "answer " .. result.action .. " " .. result.value end
            elseif selected.channel == checkpoints then
                if type(data) == "table" then lines[3] = "checkpoint " .. tostring(data.error_code) .. "|" .. tostring(data.error) end
            elseif selected.channel == navigations then
                local args = client.navigation(launch, from, data)
                if args then lines[4] = "navigated " .. table.concat(args, " ") end
            end
            present()
        end
    end
    surface:close()
    tty.stop()
end

return {main = main}
