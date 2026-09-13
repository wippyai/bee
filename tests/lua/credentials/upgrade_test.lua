-- MIT. Populate the shipped credential schema before applying file sources.
local test = require("test")
local persist = require("persist")
local migrations = require("migrations")
local broker = require("broker")
local canonical = require("canonical")
local sql = require("sql")
local RESOURCE = "bee.credentials:upgrade_db"
local function opened(count: integer): sql.DB
    local all = migrations.all()
    local selected: {migrations.Migration} = {}
    for index = 1, count do selected[index] = all[index] end
    local db, err = persist.open({resource = RESOURCE, ledger = broker.LEDGER, migrations = selected})
    if not db then error(tostring(err)) end
    return db
end
local function execute(db: sql.DB, statement: string)
    local _, err = db:execute(statement)
    if err then error(tostring(err)) end
end
local function rows(db: sql.DB, statement: string): string
    local found, err = db:query(statement)
    if not found then error(tostring(err)) end
    local encoded, encode_error = canonical.encode(found)
    if not encoded then error(tostring(encode_error)) end
    return encoded
end
local function define_tests()
    test.describe("Credential file-source upgrade", function()
        test.it("preserves populated definitions, projections, consumed generations and the first migration", function()
            local old = opened(1)
            execute(old, [[INSERT INTO bee_credential_definitions VALUES
                ('workspace','login','definition',1,'codex','env_variable','host:key','environment','OPENAI_API_KEY','config-digest','node','created','updated')]])
            execute(old, [[INSERT INTO bee_credential_projections
                (projection_id,workspace_id,name,definition_id,definition_revision,issuer_owner,issuer_incarnation,
                 subject,audience,attempt_id,profile_id,profile_digest,binding_digest,launch_policy_digest,
                 provider,projection_kind,destination,materializer,idempotency_key,materialization_generation,
                 expires_at,authorization_epoch,created_at)
                VALUES ('projection','workspace','login','definition',1,'node',1,'subject','audience','attempt',
                    'profile','profile-digest','binding-digest','policy-digest','codex','environment','OPENAI_API_KEY',
                    'materializer','retry-key',1,'2099-01-01',0,'created')]])
            execute(old, [[INSERT INTO bee_credential_generations VALUES ('projection','consumed-key',1,'runner','created')]])
            local statements = {
                "SELECT workspace_id,name,definition_id,revision,provider,source_kind,source_ref,projection_kind,destination,digest,owner_node,created_at,updated_at FROM bee_credential_definitions ORDER BY definition_id",
                "SELECT * FROM bee_credential_projections ORDER BY projection_id",
                "SELECT * FROM bee_credential_generations ORDER BY projection_id, generation_key",
                "SELECT * FROM " .. broker.LEDGER.table .. " WHERE id = 1",
            }
            local before: {string} = {}
            for index, statement in ipairs(statements) do before[index] = rows(old, statement) end
            old:release()
            local current = opened(2)
            for index, statement in ipairs(statements) do test.eq(rows(current, statement), before[index]) end
            execute(current, [[INSERT INTO bee_credential_definitions VALUES
                ('workspace','file-login','file-definition',1,'codex','fs_directory','host:login','file','auth.json','file-config-digest','node','created','updated')]])
            local after = rows(current, statements[1])
            current:release()
            local again = opened(3)
            test.eq(rows(again, statements[1]), after)
            for index = 2, 3 do test.eq(rows(again, statements[index]), before[index]) end
            local migrated, migrated_error = again:query("SELECT name,optional FROM bee_credential_definitions ORDER BY definition_id")
            test.is_nil(migrated_error)
            test.eq(#(migrated :: {unknown}), 2)
            for _, row in ipairs(migrated :: {{[string]: unknown}}) do test.eq(row.optional, 0) end
            -- Verify migration 2 schema check constraints enforce provider, source_kind and projection_kind
            local _, bad_provider = again:execute([[INSERT INTO bee_credential_definitions VALUES
                ('ws','bad-p','def-bp',1,'unsupported','fs_directory','host:login','file','auth.json','d','node','created','updated',0)]])
            test.is_true(bad_provider ~= nil)

            local _, bad_source_kind = again:execute([[INSERT INTO bee_credential_definitions VALUES
                ('ws','bad-sk','def-bsk',1,'codex','socket','host:login','file','auth.json','d','node','created','updated',0)]])
            test.is_true(bad_source_kind ~= nil)

            local _, bad_proj_kind = again:execute([[INSERT INTO bee_credential_definitions VALUES
                ('ws','bad-pk','def-bpk',1,'codex','fs_directory','host:login','socket','auth.json','d','node','created','updated',0)]])
            test.is_true(bad_proj_kind ~= nil)

            local _, bad_optional = again:execute("UPDATE bee_credential_definitions SET optional = 2 WHERE name = 'login'")
            test.is_true(bad_optional ~= nil)

            -- Verify migration ledger records all migrations and stores no secrets
            local ledger_rows, ledger_err = again:query("SELECT * FROM " .. broker.LEDGER.table .. " ORDER BY id")
            test.is_nil(ledger_err)
            test.is_true(ledger_rows ~= nil)
            test.eq(#(ledger_rows :: {unknown}), 3)
            local l1 = (ledger_rows :: {{[string]: unknown}})[1]
            local l2 = (ledger_rows :: {{[string]: unknown}})[2]
            local l3 = (ledger_rows :: {{[string]: unknown}})[3]
            test.eq(l1.name, "credentials")
            test.eq(l2.name, "file_sources")
            test.eq(l3.name, "optional_files")

            test.eq(rows(again, statements[3]), before[3])
            local full_definitions = rows(again, "SELECT * FROM bee_credential_definitions ORDER BY definition_id")
            local old_ledger = rows(again, "SELECT * FROM " .. broker.LEDGER.table .. " WHERE id <= 3 ORDER BY id")
            again:release()
            local declared = opened(4)
            test.eq(rows(declared, "SELECT * FROM bee_credential_definitions ORDER BY definition_id"), full_definitions)
            test.eq(rows(declared, "SELECT * FROM " .. broker.LEDGER.table .. " WHERE id <= 3 ORDER BY id"), old_ledger)
            for index = 2, 3 do test.eq(rows(declared, statements[index]), before[index]) end
            execute(declared, [[INSERT INTO bee_credential_definitions VALUES
                ('workspace','new-login','new-definition',1,'fixture.harness','fs_directory','host:fixture',
                 'file','login-token','new-config-digest','node','created','updated',1)]])
            local _, empty_provider = declared:execute("UPDATE bee_credential_definitions SET provider = '' WHERE name = 'new-login'")
            test.is_true(empty_provider ~= nil)
            local _, invalid_optional = declared:execute("UPDATE bee_credential_definitions SET optional = 2 WHERE name = 'new-login'")
            test.is_true(invalid_optional ~= nil)
            local preserved = rows(declared, "SELECT * FROM bee_credential_definitions ORDER BY definition_id")
            declared:release()
            local reopened = opened(4)
            test.eq(rows(reopened, "SELECT * FROM bee_credential_definitions ORDER BY definition_id"), preserved)
            test.eq(rows(reopened, statements[3]), before[3])
            reopened:release()
            local downgraded, err = persist.open({resource = RESOURCE, ledger = broker.LEDGER, migrations = {migrations.all()[1]}})
            test.is_nil(downgraded)
            test.eq(err, "credential database schema is newer")
        end)
    end)
end
return test.run_cases(define_tests)
