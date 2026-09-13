-- MIT. Hook submissions as the gateway understands them, pure: a closed
-- event catalog, the occurrence identity each event carries, the
-- allowlisted non-content fields a record keeps, the sizes and digests of
-- the content fields it never keeps, and the classification of a Codex
-- MCP call's request metadata. Nothing here reads a store or answers a
-- harness.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}
M.MAX_PAYLOAD_BYTES = 32768
M.MAX_QUEUE = 64
M.RETRY_AFTER_MS = 500
type Object = {[string]: unknown}
-- The closed catalog of events a binding may admit, as both harnesses name
-- them. Nothing outside it is accepted, whatever a harness sends.
M.EVENTS = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "SessionEnd"}
-- Fields kept verbatim: event kind, the harness's correlation claims and
-- explicitly selected non-content values. Content fields are never kept;
-- their byte length and a sha256 over their canonical JSON are, so a
-- replay can be told from a changed submission without holding content.
M.CLAIM_FIELDS = {"session_id", "turn_id", "prompt_id", "tool_use_id", "agent_id"}
-- Selected values are kept only as enumerated codes or validated bounded
-- identifiers; arbitrary text, which may carry output, paths or secrets
-- under an ordinary name, is never kept.
M.ENUMERATED = {
    source = {"startup", "resume", "clear", "compact", "fork"},
    reason = {"clear", "logout", "prompt_input_exit", "other", "resume", "bypass_permissions_disabled"},
    permission_mode = {"default", "plan", "acceptEdits", "auto", "dontAsk", "bypassPermissions", "read-only", "workspace-write", "danger-full-access"},
    error = {"rate_limit", "overloaded", "authentication_failed", "oauth_org_not_allowed", "account_on_hold", "billing_error", "invalid_request", "model_not_found", "server_error", "max_output_tokens", "cloud_credential_error", "unknown"},
    notification_type = {"permission_prompt", "idle_prompt", "elicitation_dialog", "agent_needs_input", "agent_completed", "auth_success"},
}
M.BOOLEAN_FIELDS = {"stop_hook_active"}
M.NUMBER_FIELDS = {"duration_ms"}
M.IDENTIFIER_FIELDS = {"tool_name"}
M.CONTENT_FIELDS = {"tool_input", "tool_response", "prompt", "last_assistant_message", "message", "error_details", "cwd", "transcript_path"}
-- Fields a harness could act on if they came back; they are dropped before
-- anything is recorded and never reach an answer.
M.CONTROL_FIELDS = {"decision", "continue", "stopReason", "hookSpecificOutput", "additionalContext", "systemMessage", "suppressOutput", "reason_override", "updated_input", "permission_decision"}
type Submission = {event: string, occurrence: string, ambiguous: boolean, digest: string, fields: Object}
local function member(list: {string}, wanted: string): boolean
    for _, item in ipairs(list) do
        if item == wanted then return true end
    end
    return false
end
function M.known(event: string): boolean
    return member(M.EVENTS, event)
end
local function sha(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
-- The occurrence identity an event carries, from the captures: a tool call
-- by its tool_use_id, a prompt submission by prompt_id (Claude Code) or
-- turn_id (Codex), a session start by session_id and source, a session end
-- by session_id. A stop carries no identifier of its own occurrence (a
-- prompt may stop more than once), so it is always ambiguous. An event
-- that carries none of its identifiers is ambiguous: it is recorded per
-- delivery and never merged.
function M.occurrence(event: string, payload: Object): (string, boolean)
    local session = bounds.id(payload.session_id) or ""
    if event == "PreToolUse" or event == "PostToolUse" or event == "PostToolUseFailure" then
        local id = bounds.id(payload.tool_use_id)
        if id then return "tool:" .. id, false end
        return "tool:" .. session, true
    end
    if event == "UserPromptSubmit" then
        local id = bounds.id(payload.prompt_id) or bounds.id(payload.turn_id)
        if id then return "turn:" .. id, false end
        return "turn:" .. session, true
    end
    if event == "Stop" or event == "StopFailure" then
        local id = bounds.id(payload.prompt_id) or bounds.id(payload.turn_id) or session
        return "turn:" .. id, true
    end
    if event == "SessionStart" then
        local source = bounds.id(payload.source)
        if session ~= "" and source then return "session:" .. session .. ":" .. source, false end
        return "session:" .. session, true
    end
    if session ~= "" then return "session:" .. session, false end
    return "session:", true
end
-- The command-hook wire shape reports claims in camelCase. Decode it before
-- applying the same privacy and occurrence rules as the HTTP/MCP shape. These
-- values describe the sender's own activity; they establish no authority.
local function wire_fields(payload: Object): (Object?, string?)
    if payload.conversationId == nil and payload.toolCall == nil and payload.transcriptPath == nil then return payload, nil end
    local session = bounds.id(payload.conversationId)
    if not session then return nil, "conversationId must be an identifier" end
    if payload.session_id ~= nil or payload.tool_use_id ~= nil or payload.turn_id ~= nil or payload.prompt_id ~= nil or payload.agent_id ~= nil or payload.tool_name ~= nil or payload.tool_input ~= nil or payload.transcript_path ~= nil then
        return nil, "mixed hook field schemas are not accepted"
    end
    local result: Object = {}
    for name, value in pairs(payload) do result[name] = value end
    result.session_id = session
    if payload.transcriptPath ~= nil then
        if type(payload.transcriptPath) ~= "string" then return nil, "transcriptPath must be a string" end
        result.transcript_path = payload.transcriptPath
    end
    if payload.toolCall ~= nil then
        local tool = bounds.object(payload.toolCall)
        if not tool then return nil, "toolCall must be an object" end
        local name = bounds.text(tool.name, 128)
        if not name or not name:match("^[A-Za-z0-9_.:/%-]+$") then return nil, "toolCall.name must be a tool identifier" end
        result.tool_name = name
        result.tool_input = tool.args
    end
    if payload.error ~= nil then
        if type(payload.error) ~= "string" then return nil, "command hook error must be a string" end
        if payload.error_details ~= nil then return nil, "mixed hook error fields are not accepted" end
        result.error_details = payload.error
        result.error = nil
    end
    -- A step index is not a documented stable tool occurrence ID. Ignore it,
    -- retaining the existing ambiguous-delivery semantics.
    return result, nil
end
-- normalize: what a record keeps of a payload, and nothing else.
function M.normalize(event: string, payload: Object): (Submission?, string?)
    if not M.known(event) then return nil, "event " .. event .. " is not in the hook catalog" end
    local decoded, decode_error = wire_fields(payload)
    if not decoded then return nil, decode_error end
    payload = decoded
    local fields: Object = {event = event}
    for _, name in ipairs(M.CLAIM_FIELDS) do
        local value = payload[name]
        if value ~= nil then
            local id = bounds.id(value)
            if not id then return nil, name .. " is not an identifier" end
            fields[name] = id
        end
    end
    for name, allowed in pairs(M.ENUMERATED) do
        local value = payload[name]
        if type(value) == "string" and member(allowed, value :: string) then fields[name] = value end
    end
    for _, name in ipairs(M.BOOLEAN_FIELDS) do
        if type(payload[name]) == "boolean" then fields[name] = payload[name] end
    end
    for _, name in ipairs(M.NUMBER_FIELDS) do
        if type(payload[name]) == "number" then fields[name] = payload[name] end
    end
    for _, name in ipairs(M.IDENTIFIER_FIELDS) do
        local value = payload[name]
        if type(value) == "string" and #(value :: string) <= 128 and (value :: string):match("^[A-Za-z0-9_.:/%-]+$") then fields[name] = value end
    end
    local sizes: Object = {}
    local digests: Object = {}
    for _, name in ipairs(M.CONTENT_FIELDS) do
        local value = payload[name]
        if value ~= nil then
            local encoded = canonical.encode(value)
            sizes[name] = encoded and #encoded or 0
            local sum, digest_error = sha(value)
            if not sum then return nil, name .. ": " .. tostring(digest_error) end
            digests[name] = sum
        end
    end
    fields.content_sizes = sizes
    fields.content_digests = digests
    local occurrence, ambiguous = M.occurrence(event, payload)
    local digest, digest_error = sha({event = event, occurrence = occurrence, fields = fields})
    if not digest then return nil, digest_error end
    return {event = event, occurrence = occurrence, ambiguous = ambiguous, digest = digest, fields = fields}, nil
end
-- classify: what a Codex MCP request's metadata says about its origin.
-- Version-pinned validation of a shape the executable sets, never an
-- authenticated origin: a hook-engine call carries threadId and no model
-- call fields; a model call carries callId and turn metadata.
function M.classify(meta: unknown): (string, string)
    local object = bounds.object(meta)
    if not object then return "unclassified", "no request metadata" end
    local hook = object.threadId ~= nil
    local model = object.callId ~= nil or object["x-codex-turn-metadata"] ~= nil
    if hook and not model then return "hook_engine", "threadId without model call fields" end
    if model and not hook then return "model", "model call fields" end
    if hook and model then return "mixed", "hook and model call fields together" end
    return "unclassified", "neither hook nor model call fields"
end
function M.control_free(payload: Object): Object
    local cleaned: Object = {}
    for key, value in pairs(payload) do
        if not member(M.CONTROL_FIELDS, key) then cleaned[key] = value end
    end
    return cleaned
end
local ALLOWED_STORED_FIELDS: {string} = {"event", "content_sizes", "content_digests"}
for _, name in ipairs(M.CLAIM_FIELDS) do ALLOWED_STORED_FIELDS[#ALLOWED_STORED_FIELDS + 1] = name end
for name in pairs(M.ENUMERATED) do ALLOWED_STORED_FIELDS[#ALLOWED_STORED_FIELDS + 1] = name end
for _, name in ipairs(M.BOOLEAN_FIELDS) do ALLOWED_STORED_FIELDS[#ALLOWED_STORED_FIELDS + 1] = name end
for _, name in ipairs(M.NUMBER_FIELDS) do ALLOWED_STORED_FIELDS[#ALLOWED_STORED_FIELDS + 1] = name end
for _, name in ipairs(M.IDENTIFIER_FIELDS) do ALLOWED_STORED_FIELDS[#ALLOWED_STORED_FIELDS + 1] = name end
function M.stored_fields(value: unknown): (Object?, string?)
    local object = bounds.object(value)
    if not object then return nil, "fields must be an object" end
    local unknown_field = bounds.fields(object, ALLOWED_STORED_FIELDS)
    if unknown_field then return nil, unknown_field end
    if type(object.event) ~= "string" or not M.known(object.event) then
        return nil, "invalid or unknown event in hook fields"
    end
    local fields: Object = {event = object.event}
    for _, name in ipairs(M.CLAIM_FIELDS) do
        local val = object[name]
        if val ~= nil then
            local id = bounds.id(val)
            if not id then return nil, name .. " is not an identifier" end
            fields[name] = id
        end
    end
    for name, allowed in pairs(M.ENUMERATED) do
        local val = object[name]
        if val ~= nil then
            if type(val) ~= "string" or not member(allowed, val :: string) then
                return nil, "invalid enum value for " .. name
            end
            fields[name] = val
        end
    end
    for _, name in ipairs(M.BOOLEAN_FIELDS) do
        local val = object[name]
        if val ~= nil then
            if type(val) ~= "boolean" then return nil, name .. " must be boolean" end
            fields[name] = val
        end
    end
    for _, name in ipairs(M.NUMBER_FIELDS) do
        local val = object[name]
        if val ~= nil then
            if type(val) ~= "number" or val ~= val or val == math.huge or val == -math.huge then
                return nil, name .. " must be a finite number"
            end
            fields[name] = val
        end
    end
    for _, name in ipairs(M.IDENTIFIER_FIELDS) do
        local val = object[name]
        if val ~= nil then
            if type(val) ~= "string" or #val == 0 or #val > 128 or not val:match("^[A-Za-z0-9_.:/%-]+$") then
                return nil, name .. " is not an identifier"
            end
            fields[name] = val
        end
    end
    if object.content_sizes ~= nil then
        local sizes = bounds.object(object.content_sizes)
        if not sizes then return nil, "content_sizes must be an object" end
        local clean_sizes: Object = {}
        for k, v in pairs(sizes) do
            if type(k) ~= "string" or not member(M.CONTENT_FIELDS, k) then return nil, "unknown content_sizes field: " .. tostring(k) end
            local count = bounds.count(v)
            if count == nil then return nil, "content_sizes." .. tostring(k) .. " must be a non-negative integer" end
            clean_sizes[k] = count
        end
        fields.content_sizes = clean_sizes
    end
    if object.content_digests ~= nil then
        local digests = bounds.object(object.content_digests)
        if not digests then return nil, "content_digests must be an object" end
        local clean_digests: Object = {}
        for k, v in pairs(digests) do
            if type(k) ~= "string" or not member(M.CONTENT_FIELDS, k) then return nil, "unknown content_digests field: " .. tostring(k) end
            if type(v) ~= "string" or #v ~= 64 or not v:match("^[0-9a-fA-F]+$") then
                return nil, "content_digests." .. tostring(k) .. " must be a 64-character hex digest"
            end
            clean_digests[k] = v
        end
        fields.content_digests = clean_digests
    end
    return fields, nil
end
return M
