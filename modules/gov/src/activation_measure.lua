-- MIT. Destination-local activation measurement. The host resolver supplies
-- the resolved candidate and current context; transferred reports grant
-- nothing. This module performs no I/O, approval, publication or overlay apply.
local artifact = require("artifact")
local preflight = require("preflight")
local canonical = require("canonical")
local hash = require("hash")
local bounds = require("bounds")
local migration_work = require("migration_work")
local application_admission = require("application_admission")

local M = {}
type Object = {[string]: unknown}
type Blob = {bytes: string, digest: string}
type Admission = {bytes: string, digest: string, record: {[string]: unknown}}

local function digest(bytes: string): (string?, string?)
    local measured, err = hash.sha256(bytes)
    if not measured then return nil, tostring(err or "measure activation input") end
    return measured, nil
end

-- The resolver may carry host-selected application admission, but the
-- activation boundary retains only its canonical measured bytes.  Decode and
-- remeasure it here so neither a loose digest nor a noncanonical projection
-- can become durable approval evidence.
local function admission_blob(raw: unknown): (Admission?, string?)
    if raw == nil then return nil, nil end
    local value = bounds.object(raw)
    if not value or type(value.bytes) ~= "string" or #value.bytes < 1
        or #value.bytes > application_admission.MAX_BYTES or type(value.digest) ~= "string"
        or #value.digest ~= 64 or not value.digest:match("^[0-9a-f]+$") then
        return nil, "application admission measurement is invalid"
    end
    local decoded, decode_error = application_admission.decode(value.bytes, value.digest)
    if not decoded then return nil, decode_error end
    return {bytes = decoded.bytes, digest = decoded.digest, record = decoded.record}, nil
end

function M.measure(plan_raw: unknown, candidate: preflight.Candidate,
    context: preflight.Context): ({[string]: unknown}?, string?)
    local plan = bounds.object(plan_raw)
    if not plan then return nil, "selected governance plan is malformed" end
    local owner, workspace = bounds.id(plan.owner_node), bounds.id(plan.workspace_id)
    local source, source_workspace, version = bounds.id(plan.source_node), bounds.id(plan.source_workspace), bounds.id(plan.version)
    local plan_digest = bounds.text(plan.plan_digest, 64)
    local revision, selection_revision = bounds.count(plan.revision), bounds.count(plan.selection_revision)
    if not owner or not workspace or not source or not source_workspace or not version
        or not plan_digest or #plan_digest ~= 64 or not plan_digest:match("^[0-9a-f]+$")
        or not revision or revision < 1 or not selection_revision or selection_revision < 1
        or plan.selected ~= true or plan.review_status ~= "accepted"
        or type(plan.artifact_bytes) ~= "string" or type(plan.artifact_digest) ~= "string" then
        return nil, "governance plan is not an accepted current selection"
    end
    if candidate.destination_node ~= owner or candidate.source_node ~= source then
        return nil, "local resolution does not match the selected source and destination"
    end
    local entries, artifact_error = artifact.decode(plan.artifact_bytes, plan.artifact_digest)
    if not entries then return nil, artifact_error end
    local measured_entries: {[string]: string} = {}
    for _, entry in ipairs(entries) do
        if application_admission.reserved(entry.id) then
            return nil, "portable artifact entry uses a reserved application admission identity"
        end
        if entry.kind == "ns.dependency" then
            return nil, "dependency directives cannot be activated in a process-local overlay"
        end
        local entry_bytes, entry_error = canonical.encode(entry, artifact.MAX_BYTES)
        if not entry_bytes then return nil, tostring(entry_error or "encode resolved entry") end
        local entry_digest, digest_error = digest(entry_bytes)
        if not entry_digest then return nil, digest_error end
        measured_entries[entry.id :: string] = entry_digest
    end
    for _, entry in ipairs(candidate.entries) do
        if measured_entries[entry.id] ~= entry.digest then
            return nil, "resolved candidate does not match exact artifact entry " .. entry.id
        end
        measured_entries[entry.id] = nil
    end
    if next(measured_entries) then return nil, "resolved candidate omits an exact artifact entry" end
    local report, report_error = preflight.check(candidate, context)
    if not report then return nil, report_error end
    if not report.ready then
        local reasons: {string} = {}
        for index, diagnostic in ipairs(report.diagnostics) do
            if index > 8 then break end
            reasons[#reasons + 1] = diagnostic.code .. ":" .. diagnostic.target
        end
        return nil, "destination preflight is not ready: " .. table.concat(reasons, ", ")
    end
    if #candidate.migrations > 0 then
        for _, entry in ipairs(candidate.entries) do
            if entry.auto_start then
                return nil, "migration-enabled activation does not yet admit auto-start consumers"
            end
        end
    end
    -- A runtime rebuild may assign a new numeric registry revision to the same
    -- composed state. The live preflight above checks the actual revision.
    -- Durable approval evidence normalizes that transient fence to zero while
    -- retaining the complete semantic base digest, package closure and policy.
    local durable_candidate: any = {}
    for field, value in pairs(candidate) do durable_candidate[field] = value end
    durable_candidate.base_revision = 0
    local durable_context: any = {}
    for field, value in pairs(context) do durable_context[field] = value end
    durable_context.registry_revision = 0
    local durable_report, durable_error = preflight.check(durable_candidate :: preflight.Candidate,
        durable_context :: preflight.Context)
    if not durable_report or not durable_report.ready then
        return nil, durable_error or "cannot normalize destination preflight"
    end
    local report_bytes, report_digest, encode_error = preflight.encode_report(durable_report)
    if not report_bytes or not report_digest then return nil, encode_error end
    local resolution_bytes, resolution_error = canonical.encode(durable_candidate, 1048576)
    if not resolution_bytes then return nil, resolution_error end
    local resolution_digest, measure_error = digest(resolution_bytes)
    if not resolution_digest then return nil, measure_error end
    local artifact_blob: Blob = {bytes = plan.artifact_bytes :: string, digest = plan.artifact_digest :: string}
    local work, work_error = migration_work.capture(durable_candidate :: preflight.Candidate,
        {schema_revision = artifact.SCHEMA, entries = entries, bytes = artifact_blob.bytes,
            digest = artifact_blob.digest}, durable_context :: preflight.Context)
    if not work then return nil, work_error or "capture exact migration work" end
    for _, database_binding in ipairs(work.databases) do
        if database_binding.planned then
            return nil, "migration-enabled activation currently requires an existing host-admitted database"
        end
    end
    for _, migration in ipairs(work.migrations) do
        local summary: preflight.Entry? = nil
        for _, entry in ipairs(candidate.entries) do
            if entry.id == migration.id then summary = entry; break end
        end
        if not summary then return nil, "captured migration has no measured candidate entry" end
        for _, reference in ipairs(summary.references) do
            if durable_context.entries[reference] == nil then
                return nil, "migration-enabled activation currently requires migration dependencies to be installed already"
            end
        end
    end
    local resolution_blob: Blob = {bytes = resolution_bytes, digest = resolution_digest}
    local preflight_blob: Blob = {bytes = report_bytes, digest = report_digest}
    local admission, admission_error = admission_blob((context :: any).application_admission)
    if admission_error then return nil, admission_error end
    if admission and (admission.record.workspace_id ~= workspace or admission.record.source_node ~= source
        or admission.record.source_workspace ~= source_workspace or admission.record.artifact_digest ~= artifact_blob.digest) then
        return nil, "application admission does not match the accepted plan"
    end
    return {owner_node = owner, workspace_id = workspace, source_node = source,
        source_workspace = source_workspace, version = version, plan_digest = plan_digest,
        plan_revision = revision, selection_revision = selection_revision,
        artifact_digest = artifact_blob.digest, resolution_digest = resolution_blob.digest,
        preflight_digest = preflight_blob.digest, migration_work_digest = work.digest,
        entries = entries, candidate = durable_candidate, artifact = artifact_blob, resolution = resolution_blob,
        migration_work = {bytes = work.bytes, digest = work.digest},
        preflight = preflight_blob, application_admission = admission,
        application_admission_digest = admission and admission.digest or nil, report = durable_report,
        capability_proposal = (context :: any).capability_proposal,
        capability_installed = (context :: any).capability_installed,
        capability_review = (context :: any).capability_review,
        grant_predecessor_digest = (context :: any).capability_installed
            and (context :: any).capability_installed.record_digest or nil}, nil
end

return M
