-- MIT. Focused broker test cases.
local test = require("test")
local json = require("json")
local store = require("store")
local support = require("support")
local USER = support.USER
local SENTINEL = support.SENTINEL
local SOURCE = support.SOURCE
local CODEX_LOGIN_SOURCE = support.CODEX_LOGIN_SOURCE
local CLAUDE_LOGIN_SOURCE = support.CLAUDE_LOGIN_SOURCE
local ONBOARDING_SENTINEL = support.ONBOARDING_SENTINEL
local CODEX_FILE_SENTINEL = support.CODEX_FILE_SENTINEL
local CLAUDE_FILE_SENTINEL = support.CLAUDE_FILE_SENTINEL
local DIGEST = support.DIGEST
local fresh = support.fresh
local manager = support.manager
local user = support.user
local runner = support.runner
local outsider = support.outsider
local call = support.call
local clean = support.clean
local write_file = support.write_file
local admit_sources = support.admit_sources
local M = {}
function M.define(workspace: string)
    test.it("proves secrets absent from definition/projection/materialization ledger DB and non-materialization replies", function()
        local ws = fresh("ws")
        admit_sources(ws)
        write_file(CODEX_LOGIN_SOURCE, "auth.json", CODEX_FILE_SENTINEL)
        write_file(CLAUDE_LOGIN_SOURCE, ".credentials.json", CLAUDE_FILE_SENTINEL)

        -- 1. All non-materialization replies carry only metadata and digests, never secret bytes
        local codex_def = call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}})
        test.is_true(codex_def.ok)
        clean(codex_def)

        local claude_def = call(manager, "define", {workspace_id = ws, name = "claude_login", provider = "claude", source = {kind = "fs_directory", ref = CLAUDE_LOGIN_SOURCE}})
        test.is_true(claude_def.ok)
        clean(claude_def)

        local env_def = call(manager, "define", {workspace_id = ws, name = "env_login", provider = "claude", source = {kind = "env_variable", ref = SOURCE}})
        test.is_true(env_def.ok)
        clean(env_def)

        local listed = call(manager, "list", {workspace_id = ws})
        test.is_true(listed.ok)
        clean(listed)

        local attempt = fresh("attempt")
        local codex_proj = call(user, "issue_projection", {workspace_id = ws, name = "codex_login", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("k")})
        test.is_true(codex_proj.ok)
        clean(codex_proj)
        local proj_id = codex_proj.value.projection_id

        local claude_proj = call(user, "issue_projection", {workspace_id = ws, name = "claude_login", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("k")})
        test.is_true(claude_proj.ok)
        clean(claude_proj)

        local checked = call(runner, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt})
        test.is_true(checked.ok)
        clean(checked)

        -- Materialize returns bytes once to admitted runner
        local mat = call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("gk")})
        test.is_true(mat.ok)

        -- Subsequent replay conflict reply carries no secret bytes
        local conflict = call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = mat.value.generation_key})
        test.is_false(conflict.ok)
        clean(conflict)

        -- Revocation reply carries no secret bytes
        local rev = call(user, "revoke", {projection_id = proj_id})
        test.is_true(rev.ok)
        clean(rev)

        -- Workspace epoch advance reply carries no secret bytes
        local rev_all = call(manager, "revoke_all", {workspace_id = ws})
        test.is_true(rev_all.ok)
        clean(rev_all)

        -- Capabilities reply carries no secret bytes
        local caps = call(outsider, "capabilities", {})
        test.is_true(caps.ok)
        clean(caps)

        -- 2. Inspect the persistent database and ledger tables directly
        local db, derr = store.open()
        if not db then error("open db: " .. tostring(derr)) end

        local tables = {"bee_credential_definitions", "bee_credential_projections", "bee_credential_generations", "bee_credential_epochs", "_migrations"}
        for _, tbl in ipairs(tables) do
            local found, qerr = db:query("SELECT * FROM " .. tbl)
            if not found then error("query " .. tbl .. ": " .. tostring(qerr)) end
            for _, row in ipairs(found) do
                local encoded = tostring(json.encode(row))
                test.is_nil((encoded:find(SENTINEL, 1, true)))
                test.is_nil((encoded:find("sentinel-codex-tok-123", 1, true)))
                test.is_nil((encoded:find("sentinel-claude-key-456", 1, true)))
                test.is_nil((encoded:find("chatgpt", 1, true)))
                test.is_nil((encoded:find("sessionKey", 1, true)))
                test.is_nil((encoded:find(ONBOARDING_SENTINEL, 1, true)))
                test.is_nil((encoded:find("grok-config-sentinel-23", 1, true)))
                test.is_nil((encoded:find("sentinel-grok-token-789", 1, true)))
            end
        end
        db:release()
    end)
end
return M
