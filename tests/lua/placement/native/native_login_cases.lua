-- MIT. Focused native configuration test cases.
local test = require("test")
local hash = require("hash")
local store = require("store")
local homes = require("homes")
local quote = require("quote")
local native_fixture = require("native_fixture")
local M = {}
function M.define()
    test.it("seeds fixed private login destinations and preserves harness-refreshed bytes", function()
        local session_key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("login-session")))
        local session_path = assert(homes.ensure_session(session_key))
        local source = {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.codex_login", definition_revision = 1}
        local seeded, seed_error, resumed = homes.retain_login(session_path, source, "initial-login-bytes")
        test.not_nil(seeded)
        test.is_nil(seed_error)
        test.is_false(resumed == true)
        local home = assert(homes.os_path(session_path .. "/home"))
        -- A provider owns the opaque bytes once seeded. This stands in for
        -- a harness refresh between retained launches.
        test.eq(native_fixture.shell("printf refreshed-login-bytes > " .. home .. "/.codex/auth.json"), "")
        local replayed, replay_error, replay = homes.retain_login(session_path, source, "stale-broker-bytes")
        test.not_nil(replayed)
        test.is_nil(replay_error)
        test.is_true(replay == true)
        test.eq(native_fixture.shell("cat " .. home .. "/.codex/auth.json"), "refreshed-login-bytes")
        local claude_key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("claude-login-session")))
        local claude_session = assert(homes.ensure_session(claude_key))
        local claude = assert(homes.retain_login(claude_session,
            {provider = "claude", format = native_fixture.CLAUDE_LOGIN_FORMAT, definition_id = "bee.test.claude_login", definition_revision = 1}, "claude-login-bytes"))
        test.is_true(claude:find("/.claude/.credentials.json", 1, true) ~= nil)
        local claude_home, home_error = homes.os_path(claude_session .. "/home")
        if not claude_home then error(tostring(home_error)) end
        test.eq(native_fixture.shell("cat " .. quote.posix(claude_home .. "/.claude.json")), '{"hasCompletedOnboarding":true}')
        test.eq(native_fixture.shell("printf private-settings > " .. quote.posix(claude_home .. "/.claude.json")), "")
        local _, replay_error = homes.retain_login(claude_session,
            {provider = "claude", format = native_fixture.CLAUDE_LOGIN_FORMAT, definition_id = "bee.test.claude_login", definition_revision = 1}, "stale-login")
        test.is_nil(replay_error)
        test.eq(native_fixture.shell("cat " .. quote.posix(claude_home .. "/.claude.json")), "private-settings")
    end)
    test.it("leaves Claude onboarding to the harness when no machine login is available", function()
        local key, key_error = homes.session_key(native_fixture.OWNER, native_fixture.fresh("claude-no-login"))
        if not key then error(tostring(key_error)) end
        local session_path, session_error = homes.ensure_session(key)
        if not session_path then error(tostring(session_error)) end
        local target, seed_error = homes.retain_login(session_path,
            {provider = "claude", format = native_fixture.CLAUDE_LOGIN_FORMAT, definition_id = "bee.test.claude_login", definition_revision = 1, optional = true}, nil)
        test.not_nil(target)
        test.is_nil(seed_error)
        local home, home_error = homes.os_path(session_path .. "/home")
        if not home then error(tostring(home_error)) end
        test.eq(native_fixture.shell("test ! -e " .. quote.posix(home .. "/.claude.json") .. " && printf absent"), "absent")
    end)
    test.it("retains optional login absence and preserves later private sign-in and sign-out", function()
        local session_key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("optional-login")))
        local session_path = assert(homes.ensure_session(session_key))
        local source = {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.optional_login", definition_revision = 1, optional = true}
        local created: {[string]: boolean} = {}
        local target, seed_error = homes.retain_login(session_path, source, nil, created)
        test.not_nil(target)
        test.is_nil(seed_error)
        local home = assert(homes.os_path(session_path .. "/home"))
        test.eq(native_fixture.shell("test ! -e " .. home .. "/.codex/auth.json && printf absent"), "absent")
        -- The immutable driver config can follow the intentionally empty login.
        test.not_nil(homes.write_protected(session_path, ".codex/config.toml", "approved", created, true))
        test.eq(native_fixture.shell("printf private-sign-in > " .. home .. "/.codex/auth.json"), "")
        local _, replay_error, replayed = homes.retain_login(session_path, source, "machine-login")
        test.is_nil(replay_error)
        test.is_true(replayed == true)
        test.eq(native_fixture.shell("cat " .. home .. "/.codex/auth.json"), "private-sign-in")
        test.eq(native_fixture.shell("rm " .. home .. "/.codex/auth.json"), "")
        local _, logout_error = homes.retain_login(session_path, source, "machine-login")
        test.is_nil(logout_error)
        test.eq(native_fixture.shell("test ! -e " .. home .. "/.codex/auth.json && printf absent"), "absent")
        local _, changed_error = homes.retain_login(session_path,
            {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.optional_login", definition_revision = 1}, "machine-login")
        test.eq(changed_error, "retained login source changed")
        local _, empty_error = homes.retain_login(session_path, source, "")
        test.eq(empty_error, "login bytes exceed bound")
        local _, required_error = homes.retain_login(session_path,
            {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.required_login", definition_revision = 1}, nil)
        test.eq(required_error, "required login bytes missing")
    end)
    test.it("publishes admitted setup when an optional login is absent", function()
        local session_key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("optional-login-setup")))
        local session_path = assert(homes.ensure_session(session_key))
        local format = {schema_revision = "bee.credential-format@2", environments = {}, file = {
            path = ".grok/auth.json", content_format = "json",
            initialize = {{path = ".grok/.bee-global-config.toml", content = "[ui]\ntheme = \"system\"\n", on_missing_login = true}}}}
        local source = {provider = "grok", format = format, definition_id = "bee.test.grok_login", definition_revision = 1, optional = true}
        local created: {[string]: boolean} = {}
        local target, seed_error, replayed = homes.retain_login(session_path, source, nil, created)
        test.not_nil(target)
        test.is_nil(seed_error)
        test.is_false(replayed == true)
        local home = assert(homes.os_path(session_path .. "/home"))
        test.eq(native_fixture.shell("test ! -e " .. home .. "/.grok/auth.json && printf absent"), "absent")
        test.eq(native_fixture.shell("cat " .. home .. "/.grok/.bee-global-config.toml"), "[ui]\ntheme = \"system\"\n")
        local setup_digest = assert(hash.sha256("[ui]\ntheme = \"system\"\n"))
        local base, base_error = homes.read_configuration(session_path, ".grok/.bee-global-config.toml", setup_digest)
        test.eq(base, "[ui]\ntheme = \"system\"\n")
        test.is_nil(base_error)
        local absent, absent_error = homes.read_configuration(session_path, ".grok/missing.toml", setup_digest)
        test.is_nil(absent)
        test.eq(absent_error, "configuration base is missing")
        test.is_nil(homes.read_configuration(session_path, "../escape.toml", setup_digest))
        local changed, changed_error = homes.read_configuration(session_path, ".grok/.bee-global-config.toml", string.rep("a", 64))
        test.is_nil(changed)
        test.eq(changed_error, "configuration base differs from admitted content")
        local _, replay_error, replay = homes.retain_login(session_path, source, nil, {})
        test.is_nil(replay_error)
        test.is_true(replay == true)
    end)
    test.it("refuses changed or incomplete retained login state without exposing bytes", function()
        local session_key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("login-reject-session")))
        local session_path = assert(homes.ensure_session(session_key))
        local source = {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.login_source", definition_revision = 1}
        assert(homes.retain_login(session_path, source, "opaque-login-not-in-errors"))
        for _, changed in ipairs({
            {provider = "claude", format = native_fixture.CLAUDE_LOGIN_FORMAT, definition_id = "bee.test.login_source", definition_revision = 1},
            {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.other_login_source", definition_revision = 1},
            {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.login_source", definition_revision = 2},
        }) do
            local _, changed_error = homes.retain_login(session_path, changed, "different-opaque-login-bytes")
            test.eq(changed_error, "retained login source changed")
            test.is_nil((changed_error:find("opaque-login-not-in-errors", 1, true)))
            test.is_nil((changed_error:find("different-opaque-login-bytes", 1, true)))
        end
        local partial_key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("login-partial-session")))
        local partial_session = assert(homes.ensure_session(partial_key))
        local made, made_error = homes.write_protected(partial_session, ".codex/auth.json", "partial", {[(partial_session .. "/home/.codex")] = true}, true)
        test.not_nil(made)
        test.is_nil(made_error)
        local _, partial_error = homes.retain_login(partial_session, source, "opaque-login-not-in-errors")
        test.eq(partial_error, "retained login is incomplete")
        -- This inspects the live root; the assertion is not inferred from
        -- the fs.directory manifest's requested mode.
        local root = assert(homes.os_path("/"))
        test.eq(native_fixture.shell("stat -c %a " .. root):match("%d+"), "700")
    end)
    test.it("seeds a nested component login without adopting unrelated existing directories", function()
        local key, key_error = homes.session_key(native_fixture.OWNER, native_fixture.fresh("nested-login"))
        if not key then error(tostring(key_error)) end
        local session, session_error = homes.ensure_session(key)
        if not session then error(tostring(session_error)) end
        local format = {schema_revision = "bee.credential-format@2", environments = {}, file = {
            path = ".gemini/antigravity-cli/antigravity-oauth-token", content_format = "opaque",
            initialize = {{path = ".gemini/antigravity-cli/initialized", content = "ready"}}}}
        local source = {provider = "agy", definition_id = "bee.test.nested_login", definition_revision = 1, format = format}
        local created: {[string]: boolean} = {}
        local target, seed_error = homes.retain_login(session, source, "opaque\0login", created)
        if not target then error(tostring(seed_error)) end
        test.is_true(created[session .. "/home/.gemini"] == true)
        test.is_true(created[session .. "/home/.gemini/antigravity-cli"] == true)
        local written, write_error = homes.write_protected(session, ".gemini/config/mcp_config.json", "approved", created, true)
        if not written then error(tostring(write_error)) end
        local _, replay_error, replayed = homes.retain_login(session, source, "stale")
        test.is_nil(replay_error)
        test.is_true(replayed == true)
        local bad_key, bad_key_error = homes.session_key(native_fixture.OWNER, native_fixture.fresh("existing-login-parent"))
        if not bad_key then error(tostring(bad_key_error)) end
        local bad_session, bad_error = homes.ensure_session(bad_key)
        if not bad_session then error(tostring(bad_error)) end
        local made, make_error = homes.write_protected(bad_session, ".gemini/unrelated", "existing", {}, true)
        if not made then error(tostring(make_error)) end
        local refused, refusal = homes.retain_login(bad_session, source, "secret")
        test.is_nil(refused)
        test.eq(refusal, "retained login parent already exists")
        local reserved, reserved_error = homes.decode_login_source({provider = "fixture", definition_id = "fixture", definition_revision = 1,
            format = {schema_revision = "bee.credential-format@2", environments = {}, file = {path = ".bee-retained-login-ready.json", content_format = "opaque"}}})
        test.is_nil(reserved)
        test.eq(reserved_error, "login format overlaps retained identity")
    end)
    test.it("keeps a retained home excluded when its placement is uncertain", function()
        local session_ref = native_fixture.fresh("uncertain-session")
        local first = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.retained_launch(native_fixture.OWNER, session_ref, "uncertain")))
        local db, open_error = store.open()
        if not db then error(open_error or "open store") end
        local uncertain = store.transition(db, first.attempt_id, {execution = "uncertain",
            evidence = {kind = "test.uncertain", detail = "placement outcome is not proven"}})
        db:release()
        test.eq(uncertain.ok, true)
        local blocked = native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.retained_launch(native_fixture.OWNER, session_ref, "must-not-run"))
        test.eq(blocked.error and blocked.error.code, "CONFLICT")
        test.is_true(tostring(blocked.error and blocked.error.message):find("retained session is still held", 1, true) ~= nil)
    end)
end
return M
