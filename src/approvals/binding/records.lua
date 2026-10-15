-- MIT. Records for the approvals authority.
local sql = require("sql")
local hash = require("hash")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local values = require("values")
local resources = require("resources")
local store = require("store")
local windows = require("windows")
local lifecycle = require("lifecycle")
local part_model = require("part_model")
local part_values = require("part_values")
local M = {}
type Object = part_model.Object
type Decision = part_model.Decision
type Row = part_model.Row
type ApprovalView = part_model.ApprovalView
local text = part_values.text
local request_kind = part_values.request_kind
local approval_state = part_values.approval_state
local digest_of = part_values.digest_of
function M.view(row: Row): ApprovalView
    return {request_digest = row.request_digest, lifecycle_records = row.lifecycle_records, contract_version = row.contract_version, contract = row.contract, reviewed_digest = row.reviewed_digest, effect_admission_ms = row.effect_admission_ms, effect = row.effect, window_grant = row.window_grant, allowed_by_grant = row.allowed_by_grant, window_max_ttl_ms = row.window_max_ttl_ms, reallow = row.reallow, approval_id = row.approval_id, owner_node = row.owner_node, owner_incarnation = row.owner_incarnation, workspace_id = row.workspace_id,
        requesting_session = row.requester_id:match("^bs:") and row.requester_id
            or (row.requester_id == "bee.gov.activation" and bounds.id((bounds.object(row.contract.origin) or {}).session_id) or nil),
        requester_id = row.requester_id, request_kind = row.request_kind, policy = row.policy, proposal = row.proposal, proposal_digest = row.proposal_digest,
        prompt = row.prompt, response_schema = row.response_schema, thread_id = row.thread_id, binding = row.binding, revision = row.revision, state = row.state,
        decision = row.decision, decider_id = row.decider_id, decided_at = row.decided_at, response = row.response, validated_incarnation = row.validated_incarnation,
        validated_by = row.validated_by, validated_at = row.validated_at, consumer_id = row.consumer_id, consumed_effect = row.consumed_effect,
        consumed_at = row.consumed_at, effect_completed_at = row.effect_completed_at,
        effect_result = row.effect_result,
        expires_at = row.expires_at, created_at = row.created_at, updated_at = row.updated_at}
end
local function proposal_of(value: unknown): (Object?, string?, string?, string?)
    local object = bounds.object(value)
    if not object then return nil, nil, nil, "proposal must be an object" end
    local unknown_field = bounds.fields(object, {"kind", "ref", "revision", "action_id", "input_digest", "payload", "grant_adapter"})
    if unknown_field then return nil, nil, nil, "proposal: " .. unknown_field end
    local kind = bounds.member(object.kind, part_model.PROPOSAL_KINDS)
    if not kind then return nil, nil, nil, "proposal kind must be operation or attempt" end
    local ref, revision = bounds.id(object.ref), bounds.id(object.revision)
    if not ref then return nil, nil, nil, "proposal ref is not an identifier" end
    if not revision then return nil, nil, nil, "proposal revision is not an identifier" end
    local action_id, action_valid = values.optional_id(object, "action_id")
    if not action_valid then return nil, nil, nil, "proposal action_id is not an identifier" end
    if action_id and kind ~= "attempt" then return nil, nil, nil, "proposal action_id belongs to an attempt proposal" end
    local input_digest: string? = nil
    if object.input_digest ~= nil then
        input_digest = text(object.input_digest)
        if not input_digest or not input_digest:match("^%x+$") or #input_digest ~= 64 then return nil, nil, nil, "proposal input_digest must be a sha256 hex digest" end
    end
    local payload = bounds.object(object.payload == nil and {} or object.payload)
    if not payload then return nil, nil, nil, "proposal payload must be an object" end
    local adapter = bounds.id(object.grant_adapter)
    if object.grant_adapter ~= nil then
        if not adapter then return nil,nil,nil,"proposal grant_adapter must name a registered adapter" end
        local found, err = resources.has_grant_adapter({grant_adapter = adapter})
        if not found or err then return nil,nil,nil,"proposal grant_adapter is unavailable" end
    end
    local proposal: Object = {grant_adapter = adapter,kind = kind, ref = ref, revision = revision, action_id = action_id, input_digest = input_digest, payload = payload}
    local digest, encoded, digest_error = digest_of(proposal, part_model.MAX_PROPOSAL_BYTES)
    if not digest or not encoded then return nil, nil, nil, "proposal: " .. tostring(digest_error) end
    return proposal, digest, encoded, nil
end
local function optional_text(object: Object, key: string): (string?, boolean)
    local value = object[key]
    if value == nil then return nil, true end
    if type(value) ~= "string" then return nil, false end
    return value, true
end
local function stored_json(object: Object, key: string, optional: boolean, object_only: boolean): (unknown, string?)
    local raw = object[key]
    if raw == nil and optional then return nil, nil end
    if type(raw) ~= "string" then return nil, key .. " is not stored as JSON text" end
    local value, decode_error = json.decode(raw)
    if value == nil then return nil, key .. " is corrupt: " .. tostring(decode_error or "invalid JSON") end
    if object_only and not bounds.object(value) then return nil, key .. " is not a JSON object" end
    local encoded, encode_error = canonical.encode(value)
    if not encoded or encoded ~= raw then return nil, key .. " is not canonical JSON: " .. tostring(encode_error or "encoding differs") end
    return value, nil
end
local function decode_row(raw: unknown, tx: sql.Transaction): (Row?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "approval row is not an object" end
    local approval_id = bounds.id(value.approval_id)
    local owner_node = bounds.id(value.owner_node)
    local owner_incarnation = bounds.integer(value.owner_incarnation)
    local workspace_id = bounds.id(value.workspace_id)
    local requester_id = bounds.id(value.requester_id)
    local requester_key = bounds.id(value.requester_key)
    local request_digest = value.request_digest
    local request_kind = request_kind(value.request_kind)
    local policy = bounds.id(value.policy)
    local proposal_digest = value.proposal_digest
    local revision = bounds.integer(value.revision)
    local state = approval_state(value.state)
    local raw_decision = value.decision
    local decision: Decision? = nil
    if raw_decision == "approved" or raw_decision == "denied" then decision = raw_decision end
    local expires_ms = bounds.integer(value.expires_ms)
    local expires_at = bounds.timestamp(value.expires_at)
    local created_at = bounds.timestamp(value.created_at)
    local updated_at = bounds.timestamp(value.updated_at)
    if expires_at == nil then return nil, "approval row has invalid expiry timestamp" end
    if expires_ms == nil then return nil, "approval row has invalid expiry deadline" end
    if revision == nil then return nil, "approval row has invalid revision" end
    if revision < 1 then return nil, "approval row has invalid revision" end
    if request_kind == nil then return nil, "approval row has invalid request kind" end
    if state == nil then return nil, "approval row has invalid state" end
    if not approval_id or not owner_node or not owner_incarnation or owner_incarnation < 1 or not workspace_id
        or not requester_id or not requester_key or type(request_digest) ~= "string" or #request_digest ~= 64
        or not request_digest:match("^%x+$") or not policy or type(proposal_digest) ~= "string"
        or #proposal_digest ~= 64 or not proposal_digest:match("^%x+$")
        or (raw_decision ~= nil and not decision) or (state == "decided") ~= (decision ~= nil)
        or not created_at or not updated_at then
        return nil, "approval row has invalid required fields"
    end
    local proposal_value, proposal_json_error = stored_json(value, "proposal_json", false, true)
    if proposal_json_error then return nil, proposal_json_error end
    local proposal, proposal_digest_check, proposal_json, proposal_error = proposal_of(proposal_value)
    if not proposal or not proposal_json or proposal_json ~= value.proposal_json or proposal_digest_check ~= proposal_digest then
        return nil, "approval proposal is corrupt: " .. tostring(proposal_error or "digest or canonical form differs")
    end
    local stored_proposal_json: string = proposal_json
    local prompt_value, prompt_error = stored_json(value, "prompt_json", false, true)
    if prompt_error then return nil, prompt_error end
    local prompt, content_error = values.content(prompt_value)
    if not prompt then return nil, "approval prompt is corrupt: " .. tostring(content_error) end
    local prompt_json = canonical.encode(prompt)
    if not prompt_json or prompt_json ~= value.prompt_json then return nil, "approval prompt is not canonical" end
    local schema_value, schema_error = stored_json(value, "response_schema_json", false, true)
    if schema_error then return nil, schema_error end
    local response_schema_json = value.response_schema_json
    if type(response_schema_json) ~= "string" then return nil, "approval response schema is corrupt" end
    local response_schema = bounds.object(schema_value)
    if not response_schema then return nil, "approval response schema is corrupt" end
    local thread_id, thread_valid = optional_text(value, "thread_id")
    if thread_id and not bounds.id(thread_id) then thread_valid = false end
    local binding_json, binding_text_valid = optional_text(value, "binding_json")
    if not binding_text_valid then return nil, "approval binding is corrupt" end
    local binding_value: unknown = nil
    local binding: Object? = nil
    if value.binding_json ~= nil then
        binding_value, schema_error = stored_json(value, "binding_json", true, true)
        if schema_error then return nil, schema_error end
        binding = bounds.object(binding_value)
        if not binding then return nil, "approval binding is corrupt" end
    end
    if not thread_valid or (thread_id == nil) ~= (binding == nil) then return nil, "approval thread binding is corrupt" end
    local decider_id, decider_valid = optional_text(value, "decider_id")
    if decider_id and not bounds.id(decider_id) then decider_valid = false end
    local decided_at: string? = nil
    if value.decided_at ~= nil then decided_at = bounds.timestamp(value.decided_at) end
    if not decider_valid or (value.decided_at ~= nil and not decided_at)
        or (state == "decided" and (not decider_id or not decided_at))
        or (state ~= "decided" and (decider_id ~= nil or decided_at ~= nil)) then
        return nil, "approval decision metadata is corrupt"
    end
    local response_json: string? = nil
    if value.response_json ~= nil then
        if type(value.response_json) ~= "string" then return nil, "approval response is not stored as JSON text" end
        response_json = value.response_json
    end
    local response, response_json_error = stored_json(value, "response_json", true, false)
    if response_json_error then return nil, response_json_error end
    local validated_incarnation: integer? = nil
    if value.validated_incarnation ~= nil then
        validated_incarnation = bounds.integer(value.validated_incarnation)
        if not validated_incarnation then return nil, "approval effect metadata is corrupt" end
    end
    local validated_by, validated_by_valid = optional_text(value, "validated_by")
    if validated_by and not bounds.id(validated_by) then validated_by_valid = false end
    local validated_at: string? = nil
    if value.validated_at ~= nil then validated_at = bounds.timestamp(value.validated_at) end
    local consumer_id, consumer_valid = optional_text(value, "consumer_id")
    if consumer_id and not bounds.id(consumer_id) then consumer_valid = false end
    local consumed_effect, effect_valid = optional_text(value, "consumed_effect")
    if consumed_effect and not bounds.id(consumed_effect) then effect_valid = false end
    local consumed_at: string? = nil
    if value.consumed_at ~= nil then consumed_at = bounds.timestamp(value.consumed_at) end
    local effect_completed_at: string? = nil
    if value.effect_completed_at ~= nil then effect_completed_at = bounds.timestamp(value.effect_completed_at) end
    local effect_result_json: string? = nil
    local effect_result: unknown = nil
    if value.effect_result_json ~= nil then
        if type(value.effect_result_json) ~= "string" then return nil, "approval effect result is corrupt" end
        effect_result_json = value.effect_result_json
        effect_result, schema_error = stored_json(value, "effect_result_json", true, true)
        if schema_error then return nil, schema_error end
    end
    local validated_present = validated_incarnation ~= nil or validated_by ~= nil or validated_at ~= nil
    if (value.validated_at ~= nil and not validated_at) or (value.effect_completed_at ~= nil and not effect_completed_at)
        or (validated_incarnation ~= nil and (validated_incarnation < 1 or not validated_by or not validated_at))
        or (validated_present and (not validated_incarnation or not validated_by or not validated_at))
        or not validated_by_valid or not consumer_valid or not effect_valid
        or ((consumer_id ~= nil or consumed_effect ~= nil or consumed_at ~= nil)
            and (not consumer_id or not consumed_effect or not consumed_at))
        or ((effect_completed_at ~= nil) ~= (effect_result ~= nil)) then
        return nil, "approval effect metadata is corrupt"
    end
    local scope_digest, scope_error = windows.scope_digest(proposal)
    if not scope_digest then return nil, scope_error end
    local grant: windows.Grant? = nil
    local grant_id = value.window_grant_id == nil and nil or bounds.id(value.window_grant_id)
    local automatic = value.allowed_by_grant == nil and nil or bounds.id(value.allowed_by_grant)
    if (value.window_grant_id ~= nil and not grant_id) or (value.allowed_by_grant ~= nil and (not automatic or automatic ~= grant_id)) then return nil, "approval window reference is corrupt" end
    if grant_id then
        local raw_grant, read_error = store.window(tx, grant_id)
        if read_error then return nil, read_error end
        local grant_error: string? = nil
        grant, grant_error = windows.decode(raw_grant)
        if not grant then return nil, grant_error end
        if grant.owner_node ~= owner_node or grant.workspace_id ~= workspace_id or grant.requester_id ~= requester_id
            or grant.policy ~= policy or grant.scope_digest ~= scope_digest or state ~= "decided" or decision ~= "approved" then
            return nil, "approval window does not cover this request"
        end
    end
    local policies, policies_error = resources.policies()
    if not policies then return nil, policies_error end
    local configured = policies[policy]
    local adapter, adapter_error = resources.has_grant_adapter(proposal)
    if adapter_error then return nil,adapter_error end
    local maximum = request_kind == "permission" and not adapter and configured and configured.max_ttl_ms or 0
    local previous, previous_error = store.matching_windows(tx, owner_node, workspace_id, requester_id, policy, scope_digest)
    if previous_error or not previous then return nil, previous_error end
    local prior = #previous > 0
    local contract_version = bounds.integer(value.contract_version)
    local contract = type(value.contract_json) == "string" and bounds.object(json.decode(value.contract_json)) or nil
    local reviewed_digest = bounds.text(value.reviewed_digest, 64)
    local effect_admission_ms = value.effect_admission_ms == nil and nil or bounds.integer(value.effect_admission_ms)
    local effect, effect_error = lifecycle.read(tx, approval_id)
    if not contract_version or (contract_version ~= 1 and contract_version ~= lifecycle.VERSION) or not contract or not reviewed_digest or #reviewed_digest ~= 64 or not effect
        or (value.effect_admission_ms ~= nil and not effect_admission_ms) then return nil, effect_error or "approval lifecycle is corrupt" end
    if contract_version == lifecycle.VERSION then
        local encoded = canonical.encode(contract, 32768)
        local measured = encoded and hash.sha256(encoded) or nil
        if encoded ~= value.contract_json or measured ~= reviewed_digest then return nil, "approval review digest is corrupt" end
    end
    if contract.reviewed_required == true then maximum = 0 end
    local records, records_error = lifecycle.records(tx, approval_id)
    if not records then return nil, records_error end
    local row: Row = {lifecycle_records = records, contract_version = contract_version, contract = contract, reviewed_digest = reviewed_digest,
        effect_admission_ms = effect_admission_ms, effect = effect, window_grant = grant, allowed_by_grant = automatic, window_max_ttl_ms = maximum, reallow = state == "pending" and prior, approval_id = approval_id, owner_node = owner_node, owner_incarnation = owner_incarnation,
        workspace_id = workspace_id, requester_id = requester_id, requester_key = requester_key, request_digest = request_digest,
        request_kind = request_kind, policy = policy, proposal_json = stored_proposal_json, proposal = proposal,
        proposal_digest = proposal_digest, prompt_json = prompt_json, prompt = prompt,
        response_schema_json = response_schema_json, response_schema = response_schema,
        thread_id = thread_id, binding_json = binding_json, binding = binding, revision = revision, state = state,
        decision = decision, decider_id = decider_id, decided_at = decided_at,
        response_json = response_json, response = response, validated_incarnation = validated_incarnation,
        validated_by = validated_by, validated_at = validated_at, consumer_id = consumer_id, consumed_effect = consumed_effect,
        consumed_at = consumed_at, expires_ms = expires_ms, expires_at = expires_at, created_at = created_at,
        updated_at = updated_at, effect_completed_at = effect_completed_at, effect_result_json = effect_result_json,
        effect_result = effect_result}
    return row, nil
end
local function load(tx: sql.Transaction, approval_id: string): (Row?, string?)
    local raw, err = store.request(tx, approval_id)
    if err then return nil, err end
    if raw == nil then return nil, nil end
    return decode_row(raw, tx)
end
M.decode_row = decode_row
M.load = load
M.proposal_of = proposal_of
return M
