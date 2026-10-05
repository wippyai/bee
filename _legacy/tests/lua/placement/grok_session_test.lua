-- MIT. Grok retained homes keep projected login and conversation state across turns.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local process = require("process")
local sql = require("sql")
local json = require("json")
local time = require("time")
local exec = require("exec")
local quote = require("quote")
local launch = require("grok_launch")
local configuration = require("grok_configuration")
local homes = require("homes")
local store = require("store")
local placement_service = require("placement_service")
local runner_fixture = require("runner_fixture")
local request_codec = require("request_codec")
local types = require("types")

local OWNER = "bee.test.grok_session"
local SOURCE = "bee.placement.native:grok_login_fixture"
local DIGEST = string.rep("b", 64)
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end

local function credential(method: string, value: unknown): {[string]: unknown}
    local policies: {security.Policy} = {}
    for index, name in ipairs({"bee.credentials.security:credential_manage_policy", "bee.credentials.security:credential_issue_policy"}) do
        policies[index] = assert(security.policy(name))
    end
    local caller = funcs.new():with_actor(principals.actor(OWNER, principals.workspace(value))):with_scope(security.new_scope(policies))
    local reply, err = caller:call("bee.credentials.binding:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    local decoded = principals.reply(reply)
    if not decoded.ok then error(method .. ": " .. tostring(decoded.error and decoded.error.code)) end
    return assert(bounds.object(decoded.value))
end

local function command(argv: {string}, environment: {[string]: string}?): string
    local executor = assert(exec.get("bee.placement.native.env:placement_executor"))
    local child = assert(executor:exec(quote.line(argv), {env = environment or {}}))
    local stdout = assert(child:stdout_stream())
    assert(child:start())
    local output = ""
    while true do
        local chunk: unknown = stdout:read(4096)
        if type(chunk) ~= "string" or chunk == "" then break end
        output = output .. chunk
    end
    local code = child:wait()
    stdout:close()
    executor:release()
    test.eq(code, 0, "fixture CLI succeeds with projected login and resume state")
    return output
end

local function admit_source()
    local entry = assert(registry.get("bee.credentials.env:credential_sources"))
    local data = entry.data
    data.sources[#data.sources + 1] = {ref = SOURCE, workspace_id = "*", audience = OWNER, provider = "grok",
        projection_kinds = {"file"}, path = ".grok/auth.json", write_back = true,
        setup_path = ".grok/config.toml", setup_destination = configuration.BASE_PATH,
        setup_content_format = "opaque", setup_initialize_empty = true}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    for _, name in ipairs({"bee.credentials.security:credential_file_policy", "bee.credentials.security:credential_file_write_policy"}) do
        local policy = assert(registry.get(name))
        policy.data.policy.resources = {SOURCE}
        changes:update(policy)
    end
    assert(changes:apply())
    command({"sh", "-c", "mkdir -p .wippy/grok-session-login/.grok && printf '%s' '{\"fixture\":true}' > .wippy/grok-session-login/.grok/auth.json && printf 'fixture = true\\n' > .wippy/grok-session-login/.grok/config.toml"})
end

local FIXTURE = [[
test "$GROK_HOME" = "$HOME/.grok" || exit 1
test -s "$GROK_HOME/auth.json" || exit 2
test -s "$GROK_HOME/config.toml" || exit 3
resume=
while [ "$#" -gt 0 ]; do
    if [ "$1" = -r ]; then shift; resume="$1"; fi
    shift
done
if [ -n "$resume" ]; then
    test "$resume" = fixture-conversation || exit 4
    test -f "$GROK_HOME/$resume" || exit 5
else
    test ! -e "$GROK_HOME/fixture-conversation" || exit 6
    touch "$GROK_HOME/fixture-conversation"
fi
printf turn >> "$GROK_HOME/turns"
printf ready
]]

local function turn(db: sql.DB, workspace: string, profile: string, session_ref: string?, resume: boolean): (string, string)
    local attempt_id = fresh("grok-turn")
    local projection = credential("issue_projection", {workspace_id = workspace, name = "login", audience = OWNER,
        attempt_id = attempt_id, profile_id = profile, profile_digest = DIGEST, binding_digest = DIGEST,
        launch_policy_digest = DIGEST, idempotency_key = fresh("projection")})
    local decoded = assert(launch.decode({profile_id = profile, brief = "fixture turn", permission_mode = "default",
        resume_ref = resume and "fixture-conversation" or nil, gateway_tools = {}, gateway_hooks = {}}))
    local selected = launch.specification(decoded)
    test.eq(selected.provider_home and selected.provider_home.private, true)
    local argv: {string} = {"-c", FIXTURE, "bee-grok-fixture"}
    for _, argument in ipairs(selected.argv) do argv[#argv + 1] = argument end
    selected.executable, selected.argv, selected.readiness = "sh", argv, "none"
    selected.home_ref = session_ref and "session" or nil
    selected.working_directory_ref = "project"
    local file = assert(configuration.projection({endpoint = "127.0.0.1:4312", action_id = attempt_id,
        tools = {}, hooks = {}, token_environment = "BEE_GATEWAY_TOKEN"}))
    local resources: {types.ResourceGrant} = {
        {name = "project", grant_ref = "project-grant", root_ref = "bee.placement.native:project_fixture", subpath = "", access = "write", purpose = "project"},
    }
    if session_ref then resources[#resources + 1] = {name = "session", grant_ref = "session-grant",
        root_ref = "bee.placement.native:project_fixture", subpath = "", access = "write", purpose = "session"} end
    local request: types.LaunchRequest = {
        idempotency_key = fresh("key"), owner_id = OWNER, owner_incarnation = 1, action_id = fresh("action"), attempt_id = attempt_id,
        binding_ref = "bee.driver.grok.binding:binding", policy_ref = "bee.placement.native:test_launch_policy_without_provider",
        profile_id = profile, binding_digest = DIGEST, profile_digest = DIGEST, launch = selected, session_ref = session_ref,
        resources = resources, environment = {}, environment_refs = {}, projections = {assert(bounds.id(projection.projection_id))},
        required_cleanup = "direct_process", required_exit_observation = "eof_gated",
        timeouts = {stop_grace_ms = 500, drain_ms = 1000, retain_ms = 1000},
    }
    request = assert(request_codec.decode(request))
    request.delivery = {arguments = {}, files = {file}}
    local intended = store.intend(db, request, assert(request_codec.digest(request)), assert(json.encode(request)),
        {capability = "direct_process", exit_observation = "eof_gated"})
    test.is_true(intended.ok)
    local runner = runner_fixture.claim("bee.placement.native:materialization_runner_process", request, 0)
    -- A sweep inside the materialization window finds the hosted runner
    -- present and leaves its attempt starting.
    test.is_true(placement_service.sweep().ok)
    test.eq(assert(store.attempt(db, attempt_id)).execution_state, "starting")
    local outcome = runner_fixture.prepare(runner)
    local prepared = outcome.prepared
    if not prepared then runner_fixture.release(runner); error(tostring(outcome.error)) end
    if session_ref then
        local key = assert(homes.session_key(OWNER, session_ref))
        test.eq(prepared.home_path, assert(homes.ensure_session(key)))
        test.not_nil(store.session_file_digest(db, OWNER, session_ref, configuration.BASE_PATH))
    end
    local child_argv = {selected.executable}
    for _, argument in ipairs(prepared.arguments) do child_argv[#child_argv + 1] = argument end
    test.eq(command(child_argv, prepared.environment), "ready")
    test.is_true(store.transition(db, attempt_id, {expected_execution = "starting", execution = "exited", cleanup = "complete",
        fields = {runner_pid = sql.NULL, exit_source = "runner", exit_code = 0},
        evidence = {kind = "test.child_exited", detail = "fixture child wait proves direct-process exit"}}).ok)
    runner_fixture.release(runner)
    return prepared.home_path, assert(prepared.environment.GROK_HOME)
end

local function define_tests()
    test.describe("Grok session login homes", function()
        admit_source()
        local mode = assert(registry.get("bee.placement.native.env:placement_resource_mode"))
        mode.data = {mode = "host_configured"}
        local changes = assert(registry.snapshot()):changes()
        changes:update(mode)
        assert(changes:apply())
        local window = assert(registry.get("bee.driver.grok.profiles:default_window"))
        local definition = window.data
        test.eq(definition.credentials[1], "grok_login")
        test.eq(definition.session_resource, "session")
        for _, profile in ipairs({"window", "session"}) do
            test.it(profile .. " resumes its second turn in the retained home with projected login", function()
                local workspace, session = fresh("workspace"), fresh("session")
                credential("define", {workspace_id = workspace, name = "login", provider = "grok",
                    source = {kind = "fs_directory", ref = SOURCE}, optional = true})
                local db = assert(store.open())
                local first, first_grok = turn(db, workspace, profile, session, false)
                local second, second_grok = turn(db, workspace, profile, session, true)
                db:release()
                test.eq(second, first)
                test.eq(second_grok, first_grok)
                test.eq(command({"sh", "-c", 'test "$(wc -c < "$1/turns")" -eq 8 && printf two-turns', "fixture", second_grok}), "two-turns")
            end)
        end
        test.it("keeps batch launches without a selected session home in separate attempt homes", function()
            local workspace = fresh("workspace")
            credential("define", {workspace_id = workspace, name = "login", provider = "grok",
                source = {kind = "fs_directory", ref = SOURCE}, optional = true})
            local db = assert(store.open())
            local first = turn(db, workspace, "batch", nil, false)
            local second = turn(db, workspace, "batch", nil, false)
            db:release()
            test.is_true(first ~= second)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options)
    local before = assert(registry.snapshot())
    local ok, result = pcall(cases, options)
    local changes = assert(registry.snapshot()):changes()
    for _, ref in ipairs({"bee.placement.native.env:placement_resource_mode", "bee.credentials.env:credential_sources",
        "bee.credentials.security:credential_file_policy", "bee.credentials.security:credential_file_write_policy"}) do
        changes:update(assert(before:get(ref)))
    end
    assert(changes:apply())
    if not ok then error(tostring(result)) end
    return result
end}
