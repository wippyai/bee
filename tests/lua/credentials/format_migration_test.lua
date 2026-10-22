local test = require("test")
local sql = require("sql")
local funcs = require("funcs")
local json = require("json")
local format = require("format")
local DATABASE = "bee.tests.credentials:format_migration_test_db"
local LEGACY_ENVIRONMENT = '{"environment_destination":"ANTHROPIC_API_KEY","file":{"content_format":"json","initialize":[],"path":".claude/.credentials.json"},"schema_revision":"bee.credential-format@1"}'
local LEGACY_FILE = '{"file":{"content_format":"opaque","initialize":[{"content":"{}","path":".gemini/settings.json"}],"path":".gemini/token"},"schema_revision":"bee.credential-format@1"}'
local function migrate(name: string)
    local id = "bee.credentials.migrations:" .. name
    local reply, err = funcs.call(id, {target_db = "bee:db", database_id = DATABASE, direction = "up", id = id})
    assert(not err, tostring(err))
    assert(type(reply) == "table" and reply.status ~= "error", tostring(type(reply) == "table" and reply.error))
end
local function stored(db: sql.DB, query: string): format.Format
    local rows = assert(db:query(query))
    test.eq(#rows, 1)
    local decoded, decode_error = format.decode(json.decode(rows[1].format_json))
    assert(decoded, tostring(decode_error))
    return decoded
end
local function define_tests()
    test.describe("credential format revision migration", function()
        test.it("carries frozen revision-1 formats to revision 2 with the same destinations", function()
            migrate("credentials")
            migrate("complete")
            migrate("lease")
            local db = assert(sql.get(DATABASE))
            for index, legacy in ipairs({LEGACY_ENVIRONMENT, LEGACY_FILE}) do
                local name = "legacy-" .. tostring(index)
                assert(db:execute([[INSERT INTO bee_credential_definitions (workspace_id, name, definition_id, revision, provider, source_kind,
                    source_ref, projection_kind, destination, digest, owner_node, created_at, updated_at, optional, format_json)
                    VALUES ('w', ?, ?, 1, 'claude', 'env_variable', 'bee.tests:key', 'environment', 'ANTHROPIC_API_KEY', 'd', 'node',
                    '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z', 0, ?)]], {name, name, legacy}))
                assert(db:execute([[INSERT INTO bee_credential_projections (projection_id, workspace_id, name, definition_id, definition_revision,
                    issuer_owner, issuer_incarnation, subject, audience, attempt_id, profile_id, profile_digest, binding_digest, launch_policy_digest,
                    provider, projection_kind, destination, materializer, idempotency_key, expires_at, authorization_epoch, created_at, format_json, lease_ms)
                    VALUES (?, 'w', ?, ?, 1, 'owner', 1, 'subject', 'audience', 'attempt', 'profile', 'p', 'b', 'l', 'claude', 'environment',
                    'ANTHROPIC_API_KEY', 'materializer', ?, '2026-10-01T00:00:00Z', 0, '2026-10-01T00:00:00Z', ?, 60000)]], {name, name, name, name, legacy}))
            end
            migrate("format_revision")
            migrate("format_revision")
            local environment = stored(db, "SELECT format_json FROM bee_credential_definitions WHERE name = 'legacy-1'")
            test.eq(#environment.environments, 1)
            test.eq(environment.environments[1], "ANTHROPIC_API_KEY")
            test.eq(environment.file.path, ".claude/.credentials.json")
            local file = stored(db, "SELECT format_json FROM bee_credential_definitions WHERE name = 'legacy-2'")
            test.eq(#file.environments, 0)
            test.eq(#file.file.initialize, 1)
            test.eq(file.file.initialize[1].path, ".gemini/settings.json")
            test.eq(file.file.initialize[1].content, "{}")
            test.eq(stored(db, "SELECT format_json FROM bee_credential_projections WHERE name = 'legacy-1'").environments[1], "ANTHROPIC_API_KEY")
            test.eq(stored(db, "SELECT format_json FROM bee_credential_projections WHERE name = 'legacy-2'").file.path, ".gemini/token")
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
