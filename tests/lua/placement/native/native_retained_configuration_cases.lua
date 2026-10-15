-- MIT. Focused native configuration test cases.
local test = require("test")
local bounds = require("bounds")
local hash = require("hash")
local homes = require("homes")
local quote = require("quote")
local native_fixture = require("native_fixture")
local M = {}
function M.define()
    test.it("retains structured private provider state across cleaned turn attempts", function()
        local session_ref = native_fixture.fresh("private-turn-session")
        for _, marker in ipairs({"first", "second"}) do
            local request = native_fixture.retained_launch(native_fixture.OWNER, session_ref, marker)
            local declared = assert(bounds.object(request.launch))
            declared.provider_home = {provider = "codex", private = true, variable = "CODEX_HOME", directory = ".codex", files = {{path = ".codex/history", kind = "state", optional = true, write_back = false}}}
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            test.is_true(native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt).execution_state == "exited"
            end, 8000))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
        end
        local key = assert(homes.session_key(native_fixture.OWNER, session_ref))
        local session_path = assert(homes.ensure_session(key))
        local home_path = assert(homes.os_path(session_path .. "/home"))
        test.eq(native_fixture.shell("cat " .. quote.posix(home_path .. "/marker")), "first\nsecond\n")
    end)
    test.it("retains a selected session home and publishes changed configuration", function()
        local session_ref = native_fixture.fresh("session")
        local first = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "first")
        local first_configuration = native_fixture.provider_configuration().content
        local first_prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", first))
        -- The same admitted request is a replay, including while it is
        -- the retained home's only holder.
        test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", first)).attempt_id, first_prepared.attempt_id)
        local competing = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "competing")
        local blocked = native_fixture.call(native_fixture.OWNER, "prepare", competing)
        test.eq(blocked.error and blocked.error.code, "CONFLICT")
        test.is_true(tostring(blocked.error and blocked.error.message):find("retained session is still held", 1, true) ~= nil)
        test.is_nil(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = first_prepared.attempt_id})).start_failure)
        test.is_true(native_fixture.wait_for(function()
            return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = first_prepared.attempt_id})).attempt).execution_state == "exited"
        end, 8000))
        -- Exit alone is not release: cleanup has to prove its scope.
        local exited_holder = native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.retained_launch(native_fixture.OWNER, session_ref, "exited-holder"))
        test.eq(exited_holder.error and exited_holder.error.code, "CONFLICT")
        native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = first_prepared.attempt_id}))
        native_fixture.update_codex_provider("https://gateway.example.net/v2", "gpt-5-refresh")
        local second_configuration = native_fixture.provider_configuration().content
        local second = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "second")
        local second_prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", second))
        test.is_nil(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = second_prepared.attempt_id})).start_failure)
        test.is_true(native_fixture.wait_for(function()
            return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = second_prepared.attempt_id})).attempt).execution_state == "exited"
        end, 8000))
        -- Restore the fixture provider after the changed retained launch
        -- has started; later tests must see the original host selection.
        native_fixture.update_codex_provider("https://gateway.example.net/v1", "gpt-5")
        local key, key_error = homes.session_key(native_fixture.OWNER, session_ref)
        if not key then error(tostring(key_error)) end
        local session_path, session_error = homes.ensure_session(key)
        if not session_path then error(tostring(session_error)) end
        local home_path, home_error = homes.os_path(session_path .. "/home")
        if not home_path then error(tostring(home_error)) end
        test.eq(native_fixture.shell("cat " .. home_path .. "/marker"), "first\nsecond\n")
        local sum = native_fixture.shell("sha256sum " .. home_path .. "/.codex/config.toml"):match("^([0-9a-f]+)")
        test.eq(sum, assert(hash.sha256(second_configuration)))
        local second_evidence = native_fixture.kinds(second_prepared.attempt_id)
        test.is_true(native_fixture.has(second_evidence, "configuration.materialized"))
        local first_home, first_home_error = homes.attempt_key(native_fixture.OWNER, first_prepared.attempt_id)
        if not first_home then error(tostring(first_home_error)) end
        local second_home, second_home_error = homes.attempt_key(native_fixture.OWNER, second_prepared.attempt_id)
        if not second_home then error(tostring(second_home_error)) end
        native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = second_prepared.attempt_id}))
        test.is_false(homes.attempt_exists(first_home))
        test.is_false(homes.attempt_exists(second_home))
        test.eq(native_fixture.shell("cat " .. home_path .. "/marker"), "first\nsecond\n")

        local other_owner = "bee.test.session_other"
        local other = native_fixture.retained_launch(other_owner, session_ref, "other")
        local other_prepared = native_fixture.attempt_of(native_fixture.call(other_owner, "prepare", other))
        local other_started = native_fixture.attempt_of(native_fixture.call(other_owner, "start", {attempt_id = other_prepared.attempt_id}))
        test.is_true(other_started.execution_state == "running" or other_started.execution_state == "exited")
        test.is_nil(other_started.start_failure)
        test.is_true(native_fixture.wait_for(function()
            return (native_fixture.value(native_fixture.call(other_owner, "status", {attempt_id = other_prepared.attempt_id})).attempt).execution_state == "exited"
        end, 8000))
        local other_key, other_key_error = homes.session_key(other_owner, session_ref)
        if not other_key then error(tostring(other_key_error)) end
        test.neq(other_key, key)
        local other_path, other_path_error = homes.ensure_session(other_key)
        if not other_path then error(tostring(other_path_error)) end
        local other_home, other_home_error = homes.os_path(other_path .. "/home")
        if not other_home then error(tostring(other_home_error)) end
        test.eq(native_fixture.shell("cat " .. other_home .. "/marker"), "other\n")

        test.neq(second_configuration, first_configuration)
        test.eq(native_fixture.shell("cat " .. home_path .. "/.codex/config.toml"), second_configuration)

        local direct_key, direct_key_error = homes.session_key(native_fixture.OWNER, native_fixture.fresh("session"))
        if not direct_key then error(tostring(direct_key_error)) end
        local direct_path, direct_path_error = homes.ensure_session(direct_key)
        if not direct_path then error(tostring(direct_path_error)) end
        local created: {[string]: boolean} = {}
        local written, write_error = homes.write_protected(direct_path, ".codex/config.toml", "approved", created, true)
        if not written then error(tostring(write_error)) end
        local replayed, replay_error, replay = homes.write_protected(direct_path, ".codex/config.toml", "approved", {}, true)
        if not replayed then error(tostring(replay_error)) end
        test.eq(replay, true)
        local changed, changed_error = homes.write_protected(direct_path, ".codex/config.toml", "changed", {}, true)
        test.is_nil(changed)
        test.eq(changed_error, "retained configuration differs from host-approved content")
        local unowned_key, unowned_key_error = homes.session_key(native_fixture.OWNER, native_fixture.fresh("session"))
        if not unowned_key then error(tostring(unowned_key_error)) end
        local unowned_path, unowned_path_error = homes.ensure_session(unowned_key)
        if not unowned_path then error(tostring(unowned_path_error)) end
        local made_parent, made_parent_error = homes.write_protected(unowned_path, ".codex/other.toml", "approved", {}, true)
        if not made_parent then error(tostring(made_parent_error)) end
        local adopted, adopted_error = homes.write_protected(unowned_path, ".codex/config.toml", "approved", {}, true)
        test.is_nil(adopted)
        test.eq(adopted_error, "configuration parent already exists")
        local missing = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
        missing.session_ref = native_fixture.fresh("session")
        local missing_launch = assert(bounds.object(missing.launch))
        missing_launch.home_ref = "session"
        local denied = native_fixture.call(native_fixture.OWNER, "prepare", missing)
        test.eq(denied.error and denied.error.code, "INVALID")
        test.eq(denied.error and denied.error.message, "launch.home_ref names no resource")
    end)
    test.it("creates nested configuration parents without adopting existing ancestors", function()
        local key, key_error = homes.session_key(native_fixture.OWNER, native_fixture.fresh("nested-config"))
        if not key then error(tostring(key_error)) end
        local path, path_error = homes.ensure_session(key)
        if not path then error(tostring(path_error)) end
        local created: {[string]: boolean} = {}
        local written, write_error = homes.write_protected(path, ".gemini/config/mcp_config.json", "approved", created, true)
        test.not_nil(written)
        test.is_nil(write_error)
        local sibling, sibling_error = homes.write_protected(path, ".gemini/GEMINI.md", "instructions", created, true)
        test.not_nil(sibling)
        test.is_nil(sibling_error)
        local replayed, replay_error, replay = homes.write_protected(path, ".gemini/config/mcp_config.json", "approved", {}, true)
        test.not_nil(replayed)
        test.is_nil(replay_error)
        test.is_true(replay == true)
        local refused, refused_error = homes.write_protected(path, ".gemini/new/config.json", "unapproved", {}, true)
        test.is_nil(refused)
        test.eq(refused_error, "configuration parent already exists")
    end)
    test.it("publishes bounded host configuration while preserving retained provider files", function()
        local key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("published-config")))
        local session = assert(homes.ensure_session(key))
        local home = assert(homes.os_path(session .. "/home"))
        local login = '{"access_token":"provider-refresh"}'
        local conversation = "conversation-state\nuser-owned\n"
        test.eq(native_fixture.shell("mkdir -p " .. quote.posix(home .. "/.codex/conversations")), "")
        test.eq(native_fixture.shell("printf %s " .. quote.posix(login) .. " > " .. quote.posix(home .. "/.codex/auth.json")), "")
        test.eq(native_fixture.shell("printf %s " .. quote.posix(conversation) .. " > " .. quote.posix(home .. "/.codex/conversations/thread.json")), "")

        local first = "[gateway]\nendpoint = \"https://gateway.example/v1\"\n"
        local published, publish_error, uncertain = homes.publish_configuration(session, ".codex/config.toml", first, {})
        if not published then error(tostring(publish_error)) end
        test.is_nil(publish_error)
        test.is_false(uncertain == true)
        test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/config.toml")), first)
        test.eq(native_fixture.shell("sha256sum " .. quote.posix(home .. "/.codex/config.toml")):match("^([0-9a-f]+)"), assert(hash.sha256(first)))

        -- A host refresh replaces a regular file atomically, while the
        -- provider login and conversation remain harness-owned bytes.
        local replacement = "[gateway]\nendpoint = \"https://gateway.example/v2\"\nheader = \"x-bee: refreshed\"\n"
        local replaced, replace_error, replace_uncertain = homes.publish_configuration(session, ".codex/config.toml", replacement, {})
        if not replaced then error(tostring(replace_error)) end
        test.is_nil(replace_error)
        test.is_false(replace_uncertain == true)
        test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/config.toml")), replacement)
        test.eq(native_fixture.shell("sha256sum " .. quote.posix(home .. "/.codex/config.toml")):match("^([0-9a-f]+)"), assert(hash.sha256(replacement)))
        test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/auth.json")), login)
        test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/conversations/thread.json")), conversation)

        -- A missing target is publishable when its already-existing
        -- parent is a regular directory under the selected home.
        local missing = "[limits]\nmax_retries = 3\n"
        local missing_path, missing_error, missing_uncertain = homes.publish_configuration(session, ".codex/missing.toml", missing, {})
        if not missing_path then error(tostring(missing_error)) end
        test.is_nil(missing_error)
        test.is_false(missing_uncertain == true)
        test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/missing.toml")), missing)

        local created: {[string]: boolean} = {}
        local deep = "[agent]\nmode = \"retained\"\n"
        local deep_path, deep_error, deep_uncertain = homes.publish_configuration(session, ".bee/config/nested.toml", deep, created)
        if not deep_path then error(tostring(deep_error)) end
        test.is_nil(deep_error)
        test.is_false(deep_uncertain == true)
        test.is_true(created[session .. "/home/.bee"] == true)
        test.is_true(created[session .. "/home/.bee/config"] == true)
        test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.bee/config/nested.toml")), deep)

        -- Existing nested parents may be reused safely; the target is
        -- still a newly published regular file.
        test.eq(native_fixture.shell("mkdir -p " .. quote.posix(home .. "/.gemini/config")), "")
        local nested = "{\"mcp\":{\"enabled\":true}}\n"
        local nested_path, nested_error, nested_uncertain = homes.publish_configuration(session, ".gemini/config/settings.json", nested, {})
        if not nested_path then error(tostring(nested_error)) end
        test.is_nil(nested_error)
        test.is_false(nested_uncertain == true)
        test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.gemini/config/settings.json")), nested)
        test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/auth.json")), login)
        test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/conversations/thread.json")), conversation)
    end)
    test.it("publishes bounded composed configuration without widening ordinary generated files", function()
        local session = assert(homes.ensure_session(assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("large-composition")))))
        local content = 'model = "fixture"\n# ' .. string.rep("x", 32768) .. "\n"
        test.is_nil(homes.publish_configuration(session, ".codex/config.toml", content, {}))
        local published, err = homes.publish_configuration(session, ".codex/config.toml", content, {}, true)
        test.not_nil(published)
        test.is_nil(err)
        local home = assert(homes.os_path(session .. "/home"))
        test.eq(native_fixture.shell("sha256sum " .. quote.posix(home .. "/.codex/config.toml")):match("^([0-9a-f]+)"), assert(hash.sha256(content)))
        test.is_nil(homes.publish_configuration(session, ".codex/config.toml", string.rep("x", 131073), {}, true))
        test.eq(native_fixture.shell("sha256sum " .. quote.posix(home .. "/.codex/config.toml")):match("^([0-9a-f]+)"), assert(hash.sha256(content)))
    end)
    test.it("refuses unsafe retained configuration targets and preserves existing bytes", function()
        local function new_session(label: string): (string, string)
            local key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh(label)))
            local session = assert(homes.ensure_session(key))
            local home = assert(homes.os_path(session .. "/home"))
            return session, home
        end
        local function refused(session: string, relative: string, content: string): string
            local published, publish_error, uncertain = homes.publish_configuration(session, relative, content, {})
            test.is_nil(published)
            test.not_nil(publish_error)
            test.is_false(uncertain == true)
            return tostring(publish_error)
        end

        local escaped, escaped_home = new_session("published-escape")
        test.eq(refused(escaped, "../escape.toml", "escape"), "configuration path escapes the home")
        test.eq(native_fixture.shell("test ! -e " .. quote.posix(escaped_home .. "/../escape.toml") .. " && printf absent"), "absent")

        local linked_parent, linked_parent_home = new_session("published-link-parent")
        test.eq(native_fixture.shell("mkdir -p " .. quote.posix(linked_parent_home .. "/.real-parent") .. " && ln -s .real-parent " .. quote.posix(linked_parent_home .. "/.linked-parent")), "")
        refused(linked_parent, ".linked-parent/config.toml", "must-not-follow")
        test.eq(native_fixture.shell("test ! -e " .. quote.posix(linked_parent_home .. "/.real-parent/config.toml") .. " && printf absent"), "absent")

        local linked_target, linked_target_home = new_session("published-link-target")
        test.eq(native_fixture.shell("mkdir -p " .. quote.posix(linked_target_home .. "/.codex") .. " && printf protected > " .. quote.posix(linked_target_home .. "/.codex/actual.toml") .. " && ln -s actual.toml " .. quote.posix(linked_target_home .. "/.codex/config.toml")), "")
        refused(linked_target, ".codex/config.toml", "must-not-replace-link")
        test.eq(native_fixture.shell("cat " .. quote.posix(linked_target_home .. "/.codex/actual.toml")), "protected")

        local nonregular, nonregular_home = new_session("published-nonregular")
        test.eq(native_fixture.shell("mkdir -p " .. quote.posix(nonregular_home .. "/.codex/config.toml")), "")
        refused(nonregular, ".codex/config.toml", "must-not-replace-directory")
        test.eq(native_fixture.shell("test -d " .. quote.posix(nonregular_home .. "/.codex/config.toml") .. " && printf directory"), "directory")

        local oversized, oversized_home = new_session("published-oversized")
        test.eq(native_fixture.shell("mkdir -p " .. quote.posix(oversized_home .. "/.codex") .. " && printf keep > " .. quote.posix(oversized_home .. "/.codex/config.toml")), "")
        refused(oversized, ".codex/config.toml", string.rep("x", 16 * 1024 + 1))
        test.eq(native_fixture.shell("cat " .. quote.posix(oversized_home .. "/.codex/config.toml")), "keep")

        -- Exercise the operation's boundary check against the actual
        -- placement root mode, restoring the fixture before assertions.
        local private, private_home = new_session("published-private-root")
        local root = assert(homes.os_path("/"))
        local original_mode = native_fixture.shell("stat -c %a " .. quote.posix(root)):match("^([0-7]+)")
        if not original_mode then error("read placement root mode") end
        test.eq(native_fixture.shell("chmod 0755 " .. quote.posix(root)), "")
        local ok, published, publish_error, uncertain = pcall(homes.publish_configuration, private, ".codex/config.toml", "private-check", {})
        test.eq(native_fixture.shell("chmod " .. original_mode .. " " .. quote.posix(root)), "")
        test.is_true(ok)
        test.is_nil(published)
        test.not_nil(publish_error)
        test.is_false(uncertain == true)
        test.eq(native_fixture.shell("test ! -e " .. quote.posix(private_home .. "/.codex/config.toml") .. " && printf absent"), "absent")
    end)
end
return M
