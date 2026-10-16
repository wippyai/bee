-- MIT. A restarted node restores every installed application its host rules
-- still admit. An application whose stored artifact the current rules refuse
-- stays out and is reported; the node still boots.
local test = require("test")
local bounds = require("bounds")
local json = require("json")
local sql = require("sql")
local registry = require("registry")
local harness = require("harness")
local library = require("library")
local governed = require("governed")
local test_fixtures = require("test_fixtures")
local guide = require("guide")
local artifact = require("artifact")
local application_admission = require("application_admission")
local workspace_applications = require("workspace_applications")
type Object = {[string]: unknown}

local OVERLAY = "storedrules"
local APP = "app." .. OVERLAY .. ":app"

local function entries(): {Object}
    local bytes = assert(json.encode(guide.example())):gsub("app.counter", "app." .. OVERLAY)
    return assert(json.decode(bytes)) :: {Object}
end

type Stored = {artifact_bytes: string, artifact_digest: string, admission_bytes: string, admission_digest: string}

local function stored(intent_id: string): Stored
    local db = assert(sql.get("bee:db"))
    local rows = assert(db:query("SELECT artifact_bytes, artifact_digest, application_admission_bytes, application_admission_digest, "
        .. "application_admission_generation FROM bee_governance_activation_intents WHERE intent_id = ?", {intent_id}))
    db:release()
    test.eq(#rows, 1, "the Library lists the left-out application")
    local row = assert(bounds.object(rows[1]))
    return {artifact_bytes = tostring(row.artifact_bytes), artifact_digest = tostring(row.artifact_digest),
        admission_bytes = tostring(row.application_admission_bytes), admission_digest = tostring(row.application_admission_digest)}
end

local function store(intent_id: string, value: Stored)
    local db = assert(sql.get("bee:db"))
    local _, err = db:execute("UPDATE bee_governance_activation_intents SET artifact_bytes = ?, artifact_digest = ?, "
        .. "application_admission_bytes = ?, application_admission_digest = ? WHERE intent_id = ?",
        {value.artifact_bytes, value.artifact_digest, value.admission_bytes, value.admission_digest, intent_id})
    db:release()
    if err then error(tostring(err)) end
end

-- earlier is the intent as a release that marked applications with meta.type
-- bee.app stored it: its artifact and the admission record measuring it.
local function earlier(current: Stored): Stored
    local decoded = assert(artifact.decode(current.artifact_bytes, current.artifact_digest))
    for _, entry in ipairs(decoded) do
        local meta = bounds.object(entry.meta)
        if meta and meta.type == "bee.application" then meta.type = "bee.app" end
    end
    local exact = assert(artifact.create(decoded))
    local admission = assert(application_admission.decode(current.admission_bytes, current.admission_digest))
    local record = admission.record
    record.artifact_digest = exact.digest
    local measured = assert(application_admission.measure(record))
    return {artifact_bytes = exact.bytes, artifact_digest = exact.digest,
        admission_bytes = measured.bytes, admission_digest = measured.digest}
end

local function define_tests()
    test.describe("boot recovery under current host rules", function()
        test.after_all(test_fixtures.registry_cleanup(true))
        test.it("boots without an installed application whose stored artifact the host rules refuse and reports it", function()
            local workspace = harness.isolated(OVERLAY)
            local author = harness.author(workspace, OVERLAY)
            local before = harness.running()
            local requested = harness.value(harness.deliver(author, OVERLAY, workspace, entries(), "1"))
            test.eq(harness.settle(author, OVERLAY, workspace, requested, "1").outcome, "applied")
            harness.close_presented(before)
            local owner = assert(workspace_applications.identity(workspace, OVERLAY)).overlay_owner
            local intent_id = tostring(requested.intent_id)
            local current = stored(intent_id)
            store(intent_id, earlier(current))

            local refused = harness.restart({owner})
            test.eq(#refused, 1, "the left-out application is reported")
            local reason = tostring(refused[1])
            test.contains(reason, owner)
            test.contains(reason, "meta.type bee.application")
            test.is_nil((registry.get(APP)))
            test.eq(#harness.restart({owner}), 0, "a left-out application is reported once")

            local listed = harness.value(harness.library(workspace, {operation = "activations"}))
            local shown = library.new(workspace)
            test.is_true(governed.apply_activations(shown.governed, assert(governed.reply({ok = true, replayed = false, value = listed}))))
            local rows = library.rows(shown, "installed")
            test.eq(#rows, 1, "the Library lists the left-out application")
            test.eq(rows[1].status, library.STATUS_LEFT_OUT)
            test.contains(rows[1].note, "meta.type bee.application")
            test.is_true(library.can_remove(rows[1]))

            harness.value(harness.library(workspace, {operation = "uninstall", source_workspace = OVERLAY,
                receipt_key = OVERLAY .. "-remove", expected_intent_id = intent_id}))
            local after = harness.value(harness.library(workspace, {operation = "activations"}))
            local emptied = library.new(workspace)
            test.is_true(governed.apply_activations(emptied.governed, assert(governed.reply({ok = true, replayed = false, value = after}))))
            test.eq(#library.rows(emptied, "installed"), 0, "a removed application leaves the Library")
            test.eq(#harness.restart({owner}), 0, "a removed application is not restored")
            test.is_nil((registry.get(APP)))
            harness.close_presented(before)
        end)
    end)
end

return test.run_cases(define_tests)
