-- Credential owner replies crossing into the placement materializer.
local bounds = require("bounds")
local clock = require("clock")
local formats = require("formats")
local M = {}
M.MAX_SECRET_BYTES = 8192
M.MAX_FILE_BYTES = 65536

type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}

type ProjectionKind = "environment" | "file"
type CheckedProjection = {
    projection_id: string, workspace_id: string, name: string, definition_id: string, definition_revision: integer,
    issuer_owner: string, issuer_incarnation: integer, subject: string, audience: string, attempt_id: string,
    profile_id: string, profile_digest: string, binding_digest: string, launch_policy_digest: string,
    provider: string, projection_kind: ProjectionKind, destination: string, materializer: string,
    materialization_generation: integer, expires_at: string, authorization_epoch: integer, format: formats.Format,
    revoked_at: string?, created_at: string, source_present: boolean?
}
type Expected = {projection_id: string, generation_key: string, projection_kind: ProjectionKind?, destination: string?}
type EnvironmentMaterialization =
    {projection_id: string, destination: string, projection_kind: "environment", encoding: "utf-8", generation: integer,
        generation_key: string, format: formats.Format, present: true, optional: boolean, value: string}
    | {projection_id: string, destination: string, projection_kind: "environment", encoding: "utf-8", generation: integer,
        generation_key: string, format: formats.Format, present: false, optional: true, value: nil}
type FileMaterialization =
    {projection_id: string, destination: string, projection_kind: "file", encoding: "utf-8" | "bytes", generation: integer,
        generation_key: string, format: formats.Format, definition_id: string, definition_revision: integer, provider: string,
        source_path: string, source_present: true, source_digest: string, write_back: boolean, present: true, optional: boolean, value: string}
    | {projection_id: string, destination: string, projection_kind: "file", encoding: "utf-8" | "bytes", generation: integer,
        generation_key: string, format: formats.Format, definition_id: string, definition_revision: integer, provider: string,
        source_path: string, source_present: false, source_digest: nil, write_back: boolean, present: false, optional: true, value: nil}
type Materialization = EnvironmentMaterialization | FileMaterialization

local function digest(value: unknown): string?
    local text = bounds.text(value, 64)
    if not text or #text ~= 64 or not text:match("^[0-9a-f]+$") then return nil end
    return text
end

local function projection_kind(value: unknown): ProjectionKind?
    if value == "environment" then return "environment" end
    if value == "file" then return "file" end
    return nil
end

function M.checked_projection(value: unknown, expected_id: string): (CheckedProjection?, string?)
    local object = bounds.object(value)
    if not object then return nil, "projection must be an object" end
    local unknown_field = bounds.fields(object, {"projection_id", "workspace_id", "name", "definition_id", "definition_revision", "issuer_owner", "issuer_incarnation",
        "subject", "audience", "attempt_id", "profile_id", "profile_digest", "binding_digest", "launch_policy_digest", "provider", "projection_kind",
        "destination", "materializer", "materialization_generation", "expires_at", "authorization_epoch", "format", "revoked_at", "created_at", "source_present"})
    if unknown_field then return nil, "projection: " .. unknown_field end
    local projection_id, workspace_id, name = bounds.id(object.projection_id), bounds.id(object.workspace_id), bounds.id(object.name)
    local definition_id, issuer_owner = bounds.id(object.definition_id), bounds.id(object.issuer_owner)
    local issuer_incarnation, revision = bounds.count(object.issuer_incarnation), bounds.count(object.definition_revision)
    local subject, audience, attempt_id = bounds.id(object.subject), bounds.id(object.audience), bounds.id(object.attempt_id)
    local profile_id, provider, materializer = bounds.id(object.profile_id), bounds.id(object.provider), bounds.id(object.materializer)
    local profile_digest, binding_digest, policy_digest = digest(object.profile_digest), digest(object.binding_digest), digest(object.launch_policy_digest)
    local kind = projection_kind(object.projection_kind)
    local generation, authorization_epoch = bounds.count(object.materialization_generation), bounds.count(object.authorization_epoch)
    local expires_at, created_at = bounds.timestamp(object.expires_at), bounds.timestamp(object.created_at)
    local destination = bounds.text(object.destination, 512)
    local format, format_error = formats.decode(object.format)
    local revoked_at: string? = nil
    if object.revoked_at ~= nil then revoked_at = bounds.timestamp(object.revoked_at) end
    local source_present: boolean? = nil
    if object.source_present ~= nil then
        if type(object.source_present) ~= "boolean" then return nil, "projection source_present flag is invalid" end
        source_present = object.source_present
    end
    if unknown_field then return nil, "projection: " .. unknown_field end
    if not projection_id or projection_id ~= expected_id or not workspace_id or not name or not definition_id or not issuer_owner
        or not issuer_incarnation or issuer_incarnation < 1 or not revision or revision < 1 or not subject or not audience or not attempt_id
        or not profile_id or not profile_digest or not binding_digest or not policy_digest or not provider or not kind or not destination
        or not materializer or generation == nil or authorization_epoch == nil or not expires_at or not created_at or not format then
        return nil, "projection fields are malformed: " .. tostring(format_error)
    end
    if kind == "environment" then
        if not destination:match("^[A-Z_][A-Z0-9_]*$") or source_present ~= nil then return nil, "environment projection destination or source status is invalid" end
    else
        local path = formats.path(destination)
        if not path or not format.file or type(source_present) ~= "boolean" then return nil, "file projection destination or source status is invalid" end
        destination = path
    end
    return {projection_id = projection_id, workspace_id = workspace_id, name = name, definition_id = definition_id,
        definition_revision = revision, issuer_owner = issuer_owner, issuer_incarnation = issuer_incarnation, subject = subject,
        audience = audience, attempt_id = attempt_id, profile_id = profile_id, profile_digest = profile_digest,
        binding_digest = binding_digest, launch_policy_digest = policy_digest, provider = provider, projection_kind = kind,
        destination = destination, materializer = materializer, materialization_generation = generation, expires_at = expires_at,
        authorization_epoch = authorization_epoch, format = format, revoked_at = revoked_at, created_at = created_at,
        source_present = source_present}, nil
end

function M.materialization(value: unknown, expected: Expected): (Materialization?, string?)
    local object = bounds.object(value)
    if not object then return nil, "materialization must be an object" end
    local kind = projection_kind(object.projection_kind)
    if not kind then return nil, "materialization projection kind is invalid" end
    local allowed = {"projection_id", "destination", "projection_kind", "encoding", "generation", "generation_key", "format", "present", "optional", "value"}
    if kind == "file" then
        allowed = {"projection_id", "destination", "projection_kind", "encoding", "generation", "generation_key", "format", "definition_id",
            "definition_revision", "provider", "source_path", "source_present", "source_digest", "write_back", "present", "optional", "value"}
    end
    local unknown_field = bounds.fields(object, allowed)
    local projection_id, destination = bounds.id(object.projection_id), bounds.text(object.destination, 512)
    local generation, generation_key = bounds.count(object.generation), bounds.id(object.generation_key)
    local format, format_error = formats.decode(object.format)
    if unknown_field then return nil, "materialization: " .. unknown_field end
    if not projection_id or projection_id ~= expected.projection_id then return nil, "materialization projection identity is invalid" end
    if not destination then return nil, "materialization destination is invalid" end
    if generation == nil then return nil, "materialization generation is invalid" end
    if generation < 1 then return nil, "materialization generation is invalid" end
    if generation_key == nil then return nil, "materialization generation key is invalid" end
    if generation_key ~= expected.generation_key then return nil, "materialization generation key is invalid" end
    if not format then return nil, "materialization format is invalid: " .. tostring(format_error) end
    if type(object.present) ~= "boolean" then return nil, "materialization present flag is invalid" end
    if type(object.optional) ~= "boolean" then return nil, "materialization optional flag is invalid" end
    if expected.projection_kind ~= nil and kind ~= expected.projection_kind then return nil, "materialization kind does not match its projection" end
    if expected.destination ~= nil and destination ~= expected.destination then return nil, "materialization destination does not match its projection" end
    local present: boolean = object.present
    local optional: boolean = object.optional
    if kind == "environment" then
        if not destination:match("^[A-Z_][A-Z0-9_]*$") then return nil, "environment materialization destination is invalid" end
        if object.encoding ~= "utf-8" then return nil, "environment materialization encoding is invalid" end
        if present == true then
            local secret = bounds.text(object.value, M.MAX_SECRET_BYTES)
            if not secret or secret == "" then return nil, "environment materialization value is invalid" end
            return {projection_id = projection_id, destination = destination, projection_kind = "environment", encoding = "utf-8",
                generation = generation, generation_key = generation_key, format = format, present = true, optional = optional, value = secret}, nil
        end
        if optional ~= true or object.value ~= nil then return nil, "absent environment materialization is not optional" end
        return {projection_id = projection_id, destination = destination, projection_kind = "environment", encoding = "utf-8",
            generation = generation, generation_key = generation_key, format = format, present = false, optional = true, value = nil}, nil
    end
    local file_path = formats.path(destination)
    local encoding: "utf-8" | "bytes"
    if object.encoding == "utf-8" then encoding = "utf-8"
    elseif object.encoding == "bytes" then encoding = "bytes"
    else return nil, "file materialization encoding is invalid" end
    local definition_id, provider = bounds.id(object.definition_id), bounds.id(object.provider)
    local revision = bounds.count(object.definition_revision)
    local source_path = formats.path(object.source_path)
    if not file_path then return nil, "file materialization destination is invalid" end
    local file_format = format.file
    if not file_format then return nil, "file materialization has no file format" end
    if not definition_id then return nil, "file materialization definition is invalid" end
    if not provider then return nil, "file materialization provider is invalid" end
    if revision == nil then return nil, "file materialization definition revision is invalid" end
    if revision < 1 then return nil, "file materialization definition revision is invalid" end
    if not source_path then return nil, "file materialization source path is invalid" end
    if type(object.source_present) ~= "boolean" then return nil, "file materialization source status is invalid" end
    if type(object.write_back) ~= "boolean" then return nil, "file materialization write-back flag is invalid" end
    local write_back: boolean = object.write_back
    if (file_format.content_format == "opaque") ~= (encoding == "bytes") then return nil, "file materialization encoding does not match its format" end
    if present == true then
        local content = bounds.text(object.value, M.MAX_FILE_BYTES)
        local source_digest = digest(object.source_digest)
        if object.source_present ~= true or not content or source_digest == nil then return nil, "present file materialization is malformed" end
        return {projection_id = projection_id, destination = file_path, projection_kind = "file", encoding = encoding, generation = generation,
            generation_key = generation_key, format = format, definition_id = definition_id, definition_revision = revision,
            provider = provider, source_path = source_path, source_present = true, source_digest = source_digest, write_back = write_back,
            present = true, optional = optional, value = content}, nil
    end
    if optional ~= true or object.source_present ~= false or object.source_digest ~= nil or object.value ~= nil then
        return nil, "absent file materialization is malformed"
    end
    return {projection_id = projection_id, destination = file_path, projection_kind = "file", encoding = encoding, generation = generation,
        generation_key = generation_key, format = format, definition_id = definition_id, definition_revision = revision,
        provider = provider, source_path = source_path, source_present = false, source_digest = nil, write_back = write_back,
        present = false, optional = true, value = nil}, nil
end

return M
