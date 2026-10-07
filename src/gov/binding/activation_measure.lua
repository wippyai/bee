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
local capability_grants = require("capability_grants")

local M = {}
type Object = {[string]: unknown}
type Blob = {bytes: string, digest: string}
type Admission = {bytes: string, digest: string, record: application_admission.Record}

local function digest(bytes: string): (string?, string?)
    local measured, err = hash.sha256(bytes)
    if not measured then return nil, tostring(err or "measure activation input") end
    return measured, nil
end

-- The resolver may carry host-selected application admission, but the
-- activation boundary retains only its canonical measured bytes.  Decode and
-- remeasure it here so neither a loose digest nor a noncanonical projection
-- can become durable approval evidence.
local function admission_blob(value: application_admission.Measurement): (Admission?, string?)
    if #value.bytes < 1 then return nil, "application admission measurement is invalid" end
    if #value.bytes > application_admission.MAX_BYTES then return nil, "application admission measurement is invalid" end
    if #value.digest ~= 64 then return nil, "application admission measurement is invalid" end
    if not value.digest:match("^[0-9a-f]+$") then return nil, "application admission measurement is invalid" end
    local decoded, decode_error = application_admission.decode(value.bytes, value.digest)
    if not decoded then return nil, decode_error end
    return {bytes = decoded.bytes, digest = decoded.digest, record = decoded.record}, nil
end

local function preflight_failure(report: preflight.Report, label: string): string
    local reasons: {string} = {}
    for index, diagnostic in ipairs(report.diagnostics) do
        if index > 8 then break end
        reasons[#reasons + 1] = diagnostic.code .. ":" .. diagnostic.target .. ": " .. diagnostic.message
    end
    return label .. ": " .. table.concat(reasons, ", ")
end

-- measure returns the activation facts, or the cause and whether destination
-- preflight refused the candidate on this host as opposed to failing to
-- measure it.
function M.measure(plan_raw: unknown, candidate: preflight.Candidate,
    context: preflight.Context): ({[string]: unknown}?, string?, boolean?)
    local plan = bounds.object(plan_raw)
    if not plan then return nil, "selected governance plan is malformed" end
    local owner, workspace = bounds.id(plan.owner_node), bounds.id(plan.workspace_id)
    local source, source_workspace, version = bounds.id(plan.source_node), bounds.id(plan.source_workspace), bounds.id(plan.version)
    local plan_digest = bounds.text(plan.plan_digest, 64)
    local revision, selection_revision = bounds.count(plan.revision), bounds.count(plan.selection_revision)
    if not owner then return nil, "governance plan is not an accepted current selection" end
    if not workspace then return nil, "governance plan is not an accepted current selection" end
    if not source then return nil, "governance plan is not an accepted current selection" end
    if not source_workspace then return nil, "governance plan is not an accepted current selection" end
    if not version then return nil, "governance plan is not an accepted current selection" end
    if not plan_digest then return nil, "governance plan is not an accepted current selection" end
    if #plan_digest ~= 64 then return nil, "governance plan is not an accepted current selection" end
    if not plan_digest:match("^[0-9a-f]+$") then return nil, "governance plan is not an accepted current selection" end
    if not revision then return nil, "governance plan is not an accepted current selection" end
    if revision < 1 then return nil, "governance plan is not an accepted current selection" end
    if not selection_revision then return nil, "governance plan is not an accepted current selection" end
    if selection_revision < 1 then return nil, "governance plan is not an accepted current selection" end
    if plan.selected ~= true then return nil, "governance plan is not an accepted current selection" end
    if plan.review_status ~= "accepted" then return nil, "governance plan is not an accepted current selection" end
    if type(plan.artifact_bytes) ~= "string" then return nil, "governance plan is not an accepted current selection" end
    if type(plan.artifact_digest) ~= "string" then return nil, "governance plan is not an accepted current selection" end
    if candidate.destination_node ~= owner then return nil, "local resolution does not match the selected source and destination" end
    if candidate.source_node ~= source then return nil, "local resolution does not match the selected source and destination" end
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
        measured_entries[entry.id] = entry_digest
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
    if not report.ready then return nil, preflight_failure(report, "destination preflight is not ready"), true end
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
    local durable_candidate: preflight.Candidate = {destination_node = candidate.destination_node,
        source_node = candidate.source_node, base_revision = 0, base_digest = candidate.base_digest,
        artifacts = candidate.artifacts, entries = candidate.entries, requirements = candidate.requirements,
        migrations = candidate.migrations}
    local durable_context: preflight.Context = {node_id = context.node_id, registry_revision = 0,
        registry_digest = context.registry_digest, policy_digest = context.policy_digest,
        packages = context.packages, namespaces = context.namespaces, kinds = context.kinds,
        databases = context.databases, grants = context.grants, modules = context.modules,
        database_bindings = context.database_bindings, entries = context.entries,
        installed_entries = context.installed_entries, applied = context.applied,
        applied_databases = context.applied_databases, generated_databases = context.generated_databases,
        exact_expansion = context.exact_expansion, migration_barrier = context.migration_barrier,
        auto_start = context.auto_start, super_edit = context.super_edit,
        protected = context.protected, host_evidence = context.host_evidence,
        driver_requirements = context.driver_requirements}
    local durable_report, durable_error = preflight.check(durable_candidate, durable_context)
    if not durable_report then return nil, durable_error or "cannot normalize destination preflight" end
    if not durable_report.ready then return nil, preflight_failure(durable_report, "normalized destination preflight is not ready"), true end
    local report_bytes, report_digest, encode_error = preflight.encode_report(durable_report)
    if not report_bytes then return nil, encode_error end
    if not report_digest then return nil, encode_error end
    local resolution_bytes, resolution_error = canonical.encode(durable_candidate, 1048576)
    if not resolution_bytes then return nil, resolution_error end
    local resolution_digest, measure_error = digest(resolution_bytes)
    if not resolution_digest then return nil, measure_error end
    local artifact_blob: Blob = {bytes = plan.artifact_bytes, digest = plan.artifact_digest}
    local work, work_error = migration_work.capture(durable_candidate,
        {schema_revision = artifact.SCHEMA, entries = entries, bytes = artifact_blob.bytes,
            digest = artifact_blob.digest}, durable_context)
    if not work then return nil, work_error or "capture exact migration work" end
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
    local admission_evidence = context.host_evidence.application_admission
    local admission: Admission? = nil
    if admission_evidence.kind == "measured" then
        local measured_admission, admission_error = admission_blob(admission_evidence.value)
        if not measured_admission then return nil, admission_error end
        admission = measured_admission
    end
    if admission and (admission.record.workspace_id ~= workspace or admission.record.source_node ~= source
        or admission.record.source_workspace ~= source_workspace or admission.record.artifact_digest ~= artifact_blob.digest) then
        return nil, "application admission does not match the accepted plan"
    end
    local capability_proposal: capability_grants.Proposal? = nil
    local capability_installed: capability_grants.Installed? = nil
    local capability_review: capability_grants.Review? = nil
    local capability_evidence = context.host_evidence.capability
    if capability_evidence.kind == "new" then
        capability_proposal, capability_review = capability_evidence.proposal, capability_evidence.review
    elseif capability_evidence.kind == "installed" then
        capability_proposal, capability_installed, capability_review = capability_evidence.proposal,
            capability_evidence.installed, capability_evidence.review
    end
    local result: Object = {owner_node = owner, workspace_id = workspace, source_node = source,
        source_workspace = source_workspace, version = version, plan_digest = plan_digest,
        plan_revision = revision, selection_revision = selection_revision,
        artifact_digest = artifact_blob.digest, resolution_digest = resolution_blob.digest,
        preflight_digest = preflight_blob.digest, migration_work_digest = work.digest,
        entries = entries, candidate = durable_candidate, artifact = artifact_blob, resolution = resolution_blob,
        migration_work = {bytes = work.bytes, digest = work.digest},
        preflight = preflight_blob, report = durable_report}
    if admission then
        result.application_admission = admission
        result.application_admission_digest = admission.digest
    end
    if capability_proposal then result.capability_proposal = capability_proposal end
    if capability_installed then
        result.capability_installed = capability_installed
        result.grant_predecessor_digest = capability_installed.record_digest
    end
    if capability_review then result.capability_review = capability_review end
    return result, nil
end

return M
