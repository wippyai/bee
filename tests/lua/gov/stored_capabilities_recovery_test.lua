-- MIT. An application installed while it requested capabilities through
-- ns.requirement entries stays out of a restarted node and is reported; the
-- node boots, and the person can still uninstall it.
local test = require("test")
local bounds = require("bounds")
local json = require("json")
local sql = require("sql")
local hash = require("hash")
local registry = require("registry")
local canonical = require("canonical")
local harness = require("harness")
local test_fixtures = require("test_fixtures")
local guide = require("guide")
local artifact = require("artifact")
local preflight = require("preflight")
local application_admission = require("application_admission")
local workspace_applications = require("workspace_applications")
type Object = {[string]: unknown}

local OVERLAY = "storedcaps"
local NAMESPACE = "app." .. OVERLAY
local APP = NAMESPACE .. ":app"

local function entries(): {Object}
    local bytes = assert(json.encode(guide.database_example())):gsub("app%.counter", NAMESPACE)
    return assert(json.decode(bytes)) :: {Object}
end

type Stored = {artifact_bytes: string, artifact_digest: string, resolution_bytes: string, resolution_digest: string,
    admission_bytes: string, admission_digest: string}

local function stored(intent_id: string): Stored
    local db = assert(sql.get("bee:db"))
    local rows = assert(db:query("SELECT artifact_bytes, artifact_digest, resolution_bytes, resolution_digest, "
        .. "application_admission_bytes, application_admission_digest FROM bee_governance_activation_intents WHERE intent_id = ?", {intent_id}))
    db:release()
    test.eq(#rows, 1)
    local row = assert(bounds.object(rows[1]))
    return {artifact_bytes = tostring(row.artifact_bytes), artifact_digest = tostring(row.artifact_digest),
        resolution_bytes = tostring(row.resolution_bytes), resolution_digest = tostring(row.resolution_digest),
        admission_bytes = tostring(row.application_admission_bytes), admission_digest = tostring(row.application_admission_digest)}
end

local function store(intent_id: string, value: Stored)
    local db = assert(sql.get("bee:db"))
    local _, err = db:execute("UPDATE bee_governance_activation_intents SET artifact_bytes = ?, artifact_digest = ?, "
        .. "resolution_bytes = ?, resolution_digest = ?, application_admission_bytes = ?, application_admission_digest = ? WHERE intent_id = ?",
        {value.artifact_bytes, value.artifact_digest, value.resolution_bytes, value.resolution_digest,
            value.admission_bytes, value.admission_digest, intent_id})
    db:release()
    if err then error(tostring(err)) end
end

-- requirement_form is the intent as a release that read capability requests
-- from ns.requirement entries stored it: each listed capability is an
-- ns.requirement appending to the application's .security.policies, in the
-- artifact and as a capability_request row of the stored resolution.
local function requirement_form(current: Stored): Stored
    local decoded = assert(artifact.decode(current.artifact_bytes, current.artifact_digest))
    local resolution = assert(bounds.object(json.decode(current.resolution_bytes)))
    local rows = assert(bounds.array(resolution.requirements, 128))
    for index, raw in ipairs(assert(bounds.array(resolution.capabilities, 64))) do
        local request = assert(bounds.object(raw))
        local id = NAMESPACE .. ":capability_" .. tostring(index)
        rows[#rows + 1] = {id = id, package = request.package, targets = {APP}, expected_kind = "security.policy",
            capability_request = {capability = request.capability, parameters = request.parameters, reason = request.reason,
                target = APP, path = ".security.policies +=", catalog_revision = request.catalog_revision,
                template_revision = request.template_revision}}
        decoded[#decoded + 1] = {id = id, kind = "ns.requirement",
            meta = {value_kind = "security.policy", capability = request.capability, parameters = request.parameters,
                reason = request.reason},
            data = {targets = {{entry = APP, path = ".security.policies +="}}}}
    end
    resolution.requirements = rows
    resolution.capabilities = nil
    for _, entry in ipairs(decoded) do
        local meta = bounds.object(entry.meta)
        local application = meta and bounds.object(meta.application) or nil
        if application then application.capabilities = nil end
    end
    local exact = assert(artifact.create(decoded))
    local admission = assert(application_admission.decode(current.admission_bytes, current.admission_digest))
    local record = admission.record
    record.artifact_digest = exact.digest
    local measured = assert(application_admission.measure(record))
    local resolution_bytes = assert(canonical.encode(resolution, 1048576))
    return {artifact_bytes = exact.bytes, artifact_digest = exact.digest,
        resolution_bytes = resolution_bytes, resolution_digest = assert(hash.sha256(resolution_bytes)),
        admission_bytes = measured.bytes, admission_digest = measured.digest}
end

local function define_tests()
    test.describe("boot recovery of capabilities requested through requirements", function()
        test.after_all(test_fixtures.registry_cleanup(true))
        test.it("boots without the application, reports the reinstall it needs and lets the person uninstall it", function()
            local workspace = harness.isolated(OVERLAY)
            local author = harness.author(workspace, OVERLAY)
            local before = harness.running()
            local requested = harness.value(harness.deliver(author, OVERLAY, workspace, entries(), "1.0.0"))
            test.eq(harness.settle(author, OVERLAY, workspace, requested, "1.0.0").outcome, "applied")
            harness.close_presented(before)
            local owner = assert(workspace_applications.identity(workspace, OVERLAY)).overlay_owner
            local intent_id = tostring(requested.intent_id)
            local installed = stored(intent_id)
            test.eq(#assert(bounds.array((assert(bounds.object(json.decode(installed.resolution_bytes)))).capabilities, 64)), 2)
            store(intent_id, requirement_form(installed))
            local earlier = stored(intent_id)
            local unread, unread_error = preflight.decode_candidate(earlier.resolution_bytes, earlier.resolution_digest)
            test.is_nil(unread)
            test.contains(tostring(unread_error), "install the application again")

            local refused = harness.restart({owner})
            test.eq(#refused, 1)
            local reason = tostring(refused[1])
            test.contains(reason, owner)
            test.contains(reason, "install the application again")
            test.is_nil((registry.get(APP)))

            harness.value(harness.library(workspace, {operation = "uninstall", source_workspace = OVERLAY,
                receipt_key = OVERLAY .. "-remove"}))
            test.eq(#harness.restart({owner}), 0)
            test.is_nil((registry.get(APP)))
            harness.close_presented(before)
        end)
    end)
end

return test.run_cases(define_tests)
