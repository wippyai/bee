-- MIT. One record, one bounded line: the sequence, a status glyph that
-- follows the recorded outcome and never infers success from an exit, the
-- family, the source, and a summary from the record's own body. Detail
-- lines carry identities. Every text is bounded; the view interprets
-- nothing further.
local text = require("text")
local record_types = require("record_types")
local M = {}
M.LINE_LIMIT = 200
M.DETAIL_LIMIT = 400
M.ID_LIMIT = 96
type Record = record_types.Record
type Object = {[string]: unknown}
type Row = {sequence: integer, record_id: string, kind: string, glyph: string, source: string, producer_id: string, summary: string,
    details: {string}, outcome: string, approval_id: string?, action_id: string?, turn_id: string?}
M.GLYPHS = {busy = "●", waiting_viewer = "◐", idle = "○", succeeded = "✓", failed = "!", cancelled = "×", uncertain = "?", record = "·"}
local function bound(value: unknown, limit: integer?): string
    return text.bound(value, limit or M.LINE_LIMIT)
end
local function bounded_id(value: unknown): string
    return bound(value, M.ID_LIMIT)
end
local function outcome_glyph(outcome: string): string
    if outcome == "succeeded" then return M.GLYPHS.succeeded end
    if outcome == "failed" then return M.GLYPHS.failed end
    if outcome == "cancelled" then return M.GLYPHS.cancelled end
    if outcome == "uncertain" then return M.GLYPHS.uncertain end
    return M.GLYPHS.record
end
local function content_text(content: record_types.Content?): string
    if not content then return "" end
    if content.text and content.text ~= "" then return content.text end
    if content.artifact_ref then return "artifact " .. content.artifact_ref end
    return ""
end
local function fault_text(fault: record_types.Fault?): string
    if not fault then return "" end
    return "  " .. fault.code .. ": " .. fault.message
end
local function observation(body: record_types.Observation): (string, string, string)
    local data = body.data
    if data.type == "session.state" then
        local state = data :: record_types.SessionState
        return M.GLYPHS.record, "session " .. state.state .. (state.resume_ref and (" resume " .. state.resume_ref) or ""), ""
    elseif data.type == "turn.signal" then
        local signal = data :: record_types.TurnSignal
        local glyph = signal.phase == "ended" and (signal.reported_outcome and outcome_glyph(signal.reported_outcome) or M.GLYPHS.uncertain) or M.GLYPHS.busy
        return glyph, "turn " .. signal.phase .. (signal.reported_outcome and (" reported " .. signal.reported_outcome) or ""), signal.reported_outcome or ""
    elseif data.type == "text" then
        local segment = data :: record_types.Text
        return M.GLYPHS.record, segment.channel .. " " .. segment.operation .. ": " .. segment.text, ""
    elseif data.type == "tool.call" then
        local call = data :: record_types.ToolCall
        return M.GLYPHS.busy, "tool " .. call.tool_name .. " " .. content_text(call.input), ""
    elseif data.type == "tool.result" then
        local result = data :: record_types.ToolResult
        return outcome_glyph(result.outcome), "tool result " .. result.outcome .. " " .. content_text(result.output) .. fault_text(result.error), result.outcome
    elseif data.type == "notice" then
        local notice = data :: record_types.Notice
        return notice.level == "error" and M.GLYPHS.failed or M.GLYPHS.record, "notice " .. notice.level .. " " .. notice.code .. " " .. content_text(notice.content), ""
    elseif data.type == "execution.exit" then
        local exit = data :: record_types.ExecutionExit
        -- An exit is evidence the process ended, not an outcome.
        return M.GLYPHS.record, "execution exit" .. (exit.exit_code ~= nil and (" code " .. tostring(exit.exit_code)) or "") .. (exit.signal and (" signal " .. exit.signal) or ""), ""
    end
    local extension = data :: record_types.Extension
    return M.GLYPHS.record, "extension " .. extension.event_name .. " " .. extension.event_revision, ""
end
function M.row(entry: Record): Row
    local glyph, summary, outcome = M.GLYPHS.record, "", ""
    local approval_id: string? = nil
    local parent_action_id: string? = nil
    local kind = entry.kind
    if kind == "observation" then
        glyph, summary, outcome = observation(entry.body :: record_types.Observation)
    elseif kind == "message" then
        local message = entry.body :: record_types.Message
        local recipients = #message.recipient_ids > 0 and (" to " .. table.concat(message.recipient_ids, ", ")) or ""
        summary = message.message_kind .. " from " .. message.sender_id .. recipients .. ": " .. content_text(message.content)
        if message.outcome then glyph = outcome_glyph(message.outcome); outcome = message.outcome end
    elseif kind == "action.admitted" then
        local admitted = entry.body :: record_types.Admitted
        glyph = M.GLYPHS.busy
        parent_action_id = admitted.parent_action_id
        local brief = content_text(admitted.input)
        if admitted.parent_action_id and entry.action_id then
            -- Child launches are the useful Timeline identity: keep the
            -- child action visible beside the brief that caused it.
            summary = "child action " .. bounded_id(entry.action_id) .. (brief ~= "" and (" · " .. brief) or "")
        else
            summary = "admitted " .. admitted.binding_ref .. " for " .. admitted.principal_id .. " " .. brief
        end
    elseif kind == "attempt.prepared" then
        summary = "attempt prepared"
    elseif kind == "attempt.started" then
        local started = entry.body :: record_types.Started
        glyph = M.GLYPHS.busy
        summary = "attempt started " .. started.execution_kind .. " " .. started.execution_ref .. " epoch " .. tostring(started.owner_epoch)
    elseif kind == "turn.request" then
        local request = entry.body :: record_types.TurnRequest
        glyph = M.GLYPHS.busy
        summary = "turn requested: " .. content_text(request.input)
    elseif kind == "turn.end" then
        local finished = entry.body :: record_types.TurnEnd
        glyph = outcome_glyph(finished.outcome); outcome = finished.outcome
        summary = "turn " .. finished.outcome .. fault_text(finished.error)
    elseif kind == "receipt" then
        local receipt = entry.body :: record_types.Receipt
        glyph = outcome_glyph(receipt.outcome); outcome = receipt.outcome
        summary = receipt.scope .. " receipt " .. receipt.outcome .. fault_text(receipt.error)
    elseif kind == "delivery.mark" then
        local mark = entry.body :: record_types.DeliveryMark
        glyph = mark.state == "uncertain" and M.GLYPHS.uncertain or M.GLYPHS.record
        summary = "delivery " .. mark.state .. " to " .. mark.recipient_id
        if mark.state == "uncertain" then outcome = "uncertain" end
    elseif kind == "request.answered" then
        local answered = entry.body :: record_types.Answered
        glyph = outcome_glyph(answered.outcome); outcome = answered.outcome
        summary = "request answered " .. answered.outcome .. " by " .. answered.recipient_id
    elseif kind == "approval.request" then
        local request = entry.body :: record_types.ApprovalRequest
        glyph = M.GLYPHS.waiting_viewer
        approval_id = request.approval_id
        summary = "approval " .. request.request_kind .. " asked by " .. request.requester_id .. "; decide in Approvals"
    elseif kind == "approval.transition" then
        local transition = entry.body :: record_types.ApprovalTransition
        glyph = transition.state == "approved" and M.GLYPHS.succeeded or (transition.state == "denied" and M.GLYPHS.failed or M.GLYPHS.cancelled)
        approval_id = transition.approval_id
        summary = "approval " .. transition.state
    end
    local details: {string} = {
        "record " .. entry.record_id .. "  recorded " .. entry.recorded_at .. "  producer " .. entry.producer_id .. "  source " .. entry.source,
    }
    local links: {string} = {}
    if entry.action_id then links[#links + 1] = "action " .. bounded_id(entry.action_id) end
    if parent_action_id then links[#links + 1] = "parent action " .. bounded_id(parent_action_id) end
    if entry.attempt_id then links[#links + 1] = "attempt " .. bounded_id(entry.attempt_id) end
    if entry.turn_id then links[#links + 1] = "turn " .. bounded_id(entry.turn_id) end
    if entry.correlation_id then links[#links + 1] = "correlation " .. bounded_id(entry.correlation_id) end
    if entry.causation then links[#links + 1] = "caused by " .. bounded_id(entry.causation.record_id) end
    if #links > 0 then details[#details + 1] = table.concat(links, "  ") end
    return {sequence = entry.sequence, record_id = entry.record_id, kind = kind, glyph = glyph, source = entry.source, producer_id = bound(entry.producer_id, 80),
        summary = bound(summary), details = {bound(details[1], M.DETAIL_LIMIT), details[2] and bound(details[2], M.DETAIL_LIMIT) or ""},
        outcome = outcome, approval_id = approval_id, action_id = entry.action_id, turn_id = entry.turn_id}
end
return M
