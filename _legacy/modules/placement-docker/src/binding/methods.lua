-- SPDX-License-Identifier: MIT
local process = require("process")
local security = require("security")
local registry = require("registry")
local funcs = require("funcs")
local json = require("json")
local bounds = require("bounds")
local request_codec = require("request_codec")
local profiles = require("profiles")
local spec_codec = require("spec")
local store = require("store")
local local_attempts = require("local_attempts")
local homes = require("homes")
local types = require("types")
local workdir_preparers = require("workdir_preparers")
local daemon = require("daemon")
local paths = require("paths")
local resources = require("resources")
local image_service = require("image")
local environment = require("environment")
local runtime_probe = require("runtime_probe")
local M = {}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, value: unknown, error: Fault?}
type Loaded = {row: store.Row, request: types.LaunchRequest, spec: spec_codec.Spec, attempt: types.Attempt}
local function fail(code: string, message: string): Reply return {ok = false, value = nil, error = {code = code, message = message}} end
local function succeed(value: unknown): Reply return {ok = true, value = value} end
local function actor(): string?
    local current = security.actor()
    if not current then return nil end
    return bounds.id(current:id())
end
function M.load(value: unknown, supervision: boolean?): (Loaded?, string?)
    local object = bounds.object(value)
    local id = object and bounds.id(object.attempt_id) or nil
    if not id then return nil, "attempt_id must be an identifier" end
    local db, open_error = store.open()
    if not db then return nil, open_error end
    local row, row_error = store.row(db, id)
    local attempt, attempt_error = store.attempt(db, id)
    db:release()
    if not row or not attempt then return nil, row_error or attempt_error or "attempt is not recorded" end
    if row.placement_kind ~= "docker" then return nil, "attempt belongs to another placement" end
    if not supervision and row.owner_id ~= actor() then return nil, "attempt belongs to another actor" end
    local request, request_error = store.request(row)
    if not request then return nil, request_error end
    if type(row.placement_spec_json) ~= "string" then return nil, "attempt has no frozen Docker specification" end
    local raw, parse_error = json.decode(row.placement_spec_json)
    if parse_error then return nil, "stored Docker specification is unreadable" end
    local spec, decode_error = spec_codec.decode(raw, request, attempt.request_digest)
    if not spec then return nil, decode_error end
    return {row = row, request = request, spec = spec, attempt = attempt}, nil
end
function M.change(id: string, update: store.Update): Reply
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "receipt store unavailable") end
    local result = store.transition(db, id, update)
    db:release()
    if not result.ok then return fail(result.code or "STORAGE", result.message or "receipt transition failed") end
    return succeed(result.attempt)
end
function M.ensure_image(spec: spec_codec.Spec): (boolean, string?)
    local inspected, inspect_error = daemon.inspect("image", spec.image)
    if inspected and not inspect_error then return true, nil end
    if inspect_error then return false, inspect_error end
    if not spec.image:find("@sha256:", 1, true) then return false, "local runtime image is missing; build it with make docker-runtime-image" end
    local fetching = M.change(spec.attempt_id, {evidence = {kind = "docker.image_fetching", detail = "fetching the admitted digest-pinned runtime image"}})
    if not fetching.ok then return false, "image fetch intent could not be recorded" end
    local _, pull_error = daemon.command({"docker", "--host", "unix:///var/run/docker.sock", "pull", spec.image})
    if pull_error then return false, "images/create: " .. tostring(pull_error) end
    local pulled, verify_error = daemon.inspect("image", spec.image)
    if not pulled or verify_error then return false, "images/inspect: " .. tostring(verify_error or "fetch did not produce the admitted digest") end
    local fetched = M.change(spec.attempt_id, {evidence = {kind = "docker.image_ready", detail = "admitted runtime image is available"}})
    return fetched.ok, fetched.error and fetched.error.message or nil
end
local function provider_home(loaded: Loaded): (string?, string?)
    local request = loaded.request
    local key, key_error = homes.attempt_key(request.owner_id, request.attempt_id)
    local parent = homes.ATTEMPTS
    if request.session_ref and request.launch.home_ref then
        key, key_error = homes.session_key(request.owner_id, request.session_ref)
        parent = homes.SESSIONS
    end
    if not key then return nil, key_error end
    local path, path_error = homes.os_path("/" .. parent .. "/" .. key .. "/home")
    if not path then return nil, path_error end
    local executor, executor_error = resources.executor()
    if not executor then return nil, executor_error end
    return paths.resolve(path, executor)
end
function M.find(loaded: Loaded): (spec_codec.Observation?, string?, boolean?)
    local known: string? = nil
    local known_image: string? = nil
    local recorded_identity = loaded.row.placement_identity_json
    if recorded_identity ~= nil then
        if type(recorded_identity) ~= "string" then return nil, "recorded container identity is malformed" end
        local identity, parse_error = json.decode(recorded_identity)
        local object = bounds.object(identity)
        known = object and spec_codec.container_id(object.backend_ref) or nil
        known_image = object and bounds.line(object.observed_image_digest, 71) or nil
        if parse_error or not known or not known_image or #known_image ~= 71 or not known_image:match("^sha256:[0-9a-f]+$") then return nil, "recorded container identity is malformed" end
    end
    local home, home_error = provider_home(loaded)
    if not home then return nil, home_error end
    if known and known_image then
        local inspected, inspect_error = daemon.inspect("container", known)
        if not inspected and not inspect_error then return nil, nil, true end
        if inspect_error or not inspected then return nil, inspect_error or "Docker container inspection returned no object" end
        local verified, verify_error = spec_codec.inspect(inspected, loaded.spec, home, known_image)
        return verified, verify_error, false
    end
    local image, image_error = daemon.inspect("image", loaded.spec.image)
    local image_object = bounds.object(image)
    local image_id = image_object and bounds.line(image_object.Id, 71) or nil
    if not image_id then return nil, image_error or "Docker image digest inspection returned no immutable ID" end
    if image_error or not image_id:match("^sha256:[0-9a-f]+$") or #image_id ~= 71 then
        return nil, image_error or "Docker image digest inspection returned no immutable ID"
    end
    local raw, list_error = daemon.containers(image_id)
    if list_error then return nil, list_error end
    local values = bounds.array(raw, 1024)
    if not values then return nil, "Docker container inventory is malformed or exceeds its bound" end
    local found: spec_codec.Observation? = nil
    for _, value in ipairs(values) do
        local item = bounds.object(value)
        local ref = item and spec_codec.container_id(item.Id) or nil
        if not ref then return nil, "Docker inventory has an invalid container ID" end
        if not known or ref == known then
            local inspected, inspect_error = daemon.inspect("container", ref)
            if inspect_error or not inspected then return nil, inspect_error or "Docker container inspection returned no object" end
            local attempt, attempt_error = spec_codec.attempt(inspected)
            if known or attempt == loaded.spec.attempt_id then
                if attempt_error then return nil, attempt_error end
                local verified, verify_error = spec_codec.inspect(inspected, loaded.spec, home, image_id)
                if not verified then return nil, verify_error end
                if found then return nil, "multiple containers have this attempt identity" end
                found = verified
            end
        end
    end
    if not found then return nil, nil, true end
    if not known then
        local identity_json = json.encode(found)
        local recorded = M.change(loaded.attempt.attempt_id, {fields = {placement_identity_json = identity_json},
            evidence = {kind = "docker.identified", detail = "container " .. found.backend_ref .. " matches attempt environment, provider home and image digest"}})
        if not recorded.ok then return nil, "container identity could not be recorded" end
        local row: store.Row = loaded.row
        row.placement_identity_json = identity_json
    end
    return found, nil, false
end
function M.prepare(value: unknown): Reply
    local input = bounds.object(value)
    if not input then return fail("INVALID", "Docker preparation must be an object") end
    local progress_recipient: string? = nil
    if input.progress_recipient ~= nil then
        progress_recipient = bounds.line(input.progress_recipient, 512)
        if not progress_recipient then return fail("INVALID", "invalid image progress recipient") end
    end
    local launch: {[string]: unknown} = {}
    for key, item in pairs(input) do if key ~= "progress_recipient" then launch[key] = item end end
    if environment.revoked() then return fail("DENIED", "Docker network and gateway admission was revoked") end
    local request, decode_error = request_codec.decode(launch)
    if not request then return fail("INVALID", decode_error or "invalid launch request") end
    if request.owner_id ~= actor() then return fail("DENIED", "Docker request belongs to another actor") end
    if not request.placement_profile_ref then return fail("DENIED", "Docker launch requires a host-admitted placement profile") end
    local pinned, pin_error = registry.snapshot()
    if not pinned then return fail("UNAVAILABLE", tostring(pin_error)) end
    local profile, profile_error = profiles.resolve(pinned, request.placement_profile_ref)
    if not profile then return fail("DENIED", profile_error or "placement profile unavailable") end
    local tuned, tune_error = profiles.tune(profile, request.preferences and request.preferences.docker_overrides)
    if not tuned then return fail("DENIED", tune_error or "Docker override refused") end
    profile = tuned
    local admission_error = spec_codec.admit(profile, request)
    if admission_error then return fail("DENIED", admission_error) end
    if profile.profile.network ~= "none" then
        local network, network_error = daemon.inspect("network", profile.profile.network or "")
        if not network then return fail("UNAVAILABLE", network_error or "host-selected Docker network is missing: " .. (profile.profile.network or "")) end
    end
    if request.gateway and (request.gateway.endpoint:match("^127%.") or request.gateway.endpoint:match("^localhost:")
        or request.gateway.endpoint:match("^%[::1%]:")) then
        return fail("UNAVAILABLE", "Docker gateway is bound to host loopback; the host must select a restricted reachable interface")
    end
    local image, route, image_error = image_service.resolve(profile, progress_recipient)
    if image_error then return fail("UNAVAILABLE", image_error) end
    local spec, spec_error = spec_codec.resolve(profile, request, nil, image, route)
    if not spec then return fail("DENIED", spec_error or "Docker specification refused") end
    local encoded, encode_error = json.encode(spec)
    if not encoded then return fail("INVALID", tostring(encode_error)) end
    return local_attempts.prepare_local(request, {binding = spec_codec.BINDING, kind = "docker", spec_json = encoded,
        home_directory = spec_codec.HOME, capability = "contained_tree", exit_observation = "independent", stdin_close = true})
end
function M.prepare_environment(value: unknown): Reply
    local input = bounds.object(value)
    if not input or bounds.fields(input, {"placement_profile_ref", "workspace_id", "progress_recipient", "revoke"}) then return fail("INVALID", "invalid Docker environment request") end
    local ref, workspace = bounds.id(input.placement_profile_ref), bounds.id(input.workspace_id)
    if not ref or not workspace then return fail("INVALID", "Docker environment requires a host profile and workspace") end
    if input.revoke ~= nil and type(input.revoke) ~= "boolean" then return fail("INVALID", "revoke must be boolean") end
    if input.revoke == true and not security.can("bee.placement.environment.revoke", ref) then return fail("DENIED", "only the person may revoke Docker environment admission") end
    local pinned = registry.snapshot()
    local profile = pinned and profiles.resolve(pinned, ref)
    if not profile or profile.profile.placement_binding ~= spec_codec.BINDING then return fail("DENIED", "profile does not select Docker") end
    if input.revoke ~= true then
        if profile.profile.network == "none" then return succeed({}) end
        local existing, network_error = daemon.inspect("network", profile.profile.network or "")
        if network_error then return fail("UNAVAILABLE", network_error) end
        local raw = funcs.call("bee.gateway.binding:address", {})
        local endpoint = bounds.object(raw)
        if existing and endpoint and type(endpoint.address) == "string" and not endpoint.address:match("^127%.") then
            if not environment.recorded() then return succeed({address = endpoint.address}) end
        end
    end
    local recipient = input.progress_recipient == nil and tostring(process.pid()) or bounds.line(input.progress_recipient,512)
    if not recipient then return fail("INVALID", "invalid environment progress recipient") end
    local address, _, error = image_service.resolve(profile, recipient, input.revoke == true and "revoke" or "environment", workspace)
    if error then return fail("UNAVAILABLE", error) end
    return succeed({address = address})
end
function M.start(value: unknown): Reply
    local loaded, load_error = M.load(value)
    if not loaded then return fail("DENIED", load_error or "attempt unavailable") end
    return local_attempts.start_local(value, "bee.placement.docker.service:runner")
end
function M.reconcile(value: unknown): Reply
    local loaded, load_error = M.load(value)
    if not loaded then return fail("DENIED", load_error or "attempt unavailable") end
    return M.reconcile_loaded(loaded)
end
function M.reconcile_loaded(loaded: Loaded): Reply
    if loaded.attempt.execution_state == "start_failed" or loaded.attempt.execution_state == "intended" then return succeed(loaded.attempt) end
    if loaded.attempt.execution_state == "starting" then return succeed(loaded.attempt) end
    local found, find_error, absent = M.find(loaded)
    if find_error then
        if loaded.attempt.execution_state == "exited" then return fail("UNAVAILABLE", find_error) end
        return M.change(loaded.attempt.attempt_id, {execution = "uncertain", evidence = {kind = "docker.unobserved", detail = find_error}})
    end
    if absent then
        if loaded.attempt.execution_state == "exited" then return succeed(loaded.attempt) end
        -- Creation intent is not absence proof after a lost dispatch.
        return M.change(loaded.attempt.attempt_id, {execution = "uncertain", evidence = {kind = "docker.missing", detail = "attempt container is absent; terminal outcome is unknown"}})
    end
    if not found then return fail("UNAVAILABLE", "Docker observation is missing") end
    local fields: {[string]: unknown} = {placement_identity_json = json.encode(found)}
    if found.state == "exited" or found.state == "stopped" then
        if loaded.attempt.execution_state == "exited" then return succeed(loaded.attempt) end
        local_attempts.retire_gateway(loaded.attempt, "container exit observed")
        fields.exit_source = "reconcile"
        fields.exit_code = found.exit_code
        return M.change(loaded.attempt.attempt_id, {execution = "exited", fields = fields,
            evidence = {kind = "docker.exited", detail = "container " .. found.backend_ref .. " is " .. found.state .. "; exit result may be unknown"}})
    end
    local refused, subject = local_attempts.check_grants(loaded.row, loaded.request)
    if refused or environment.revoked() then
        local noted = M.change(loaded.attempt.attempt_id, {evidence = {kind = tostring(subject) .. ".revoked", detail = "recorded authorization no longer holds; stopping container"}})
        if not noted.ok then return noted end
        return M.stop_loaded(loaded, {mode = "forced"})
    end
    -- A live realization is retained after owner restart; it is never invoked again.
    return M.change(loaded.attempt.attempt_id, {fields = fields, evidence = {kind = "docker.alive", detail = "container " .. found.backend_ref .. " remains " .. found.state}})
end
function M.status(value: unknown): Reply
    local loaded, load_error = M.load(value)
    if not loaded then return fail("DENIED", load_error or "attempt unavailable") end
    local found, find_error, absent = M.find(loaded)
    return succeed({attempt = loaded.attempt, private_home = loaded.request.session_ref and true or nil,
        liveness = {observed = find_error == nil, alive = found and found.state == "running" or false,
            at = store.now(), detail = find_error or (absent and "exact container absent" or "exact container observed")}})
end
function M.stop(value: unknown): Reply
    local loaded, load_error = M.load(value)
    if not loaded then return fail("DENIED", load_error or "attempt unavailable") end
    return M.stop_loaded(loaded, value)
end
function M.stop_loaded(loaded: Loaded, value: unknown): Reply
    if loaded.attempt.execution_state == "intended" then
        return M.change(loaded.attempt.attempt_id, {expected_execution = "intended", execution = "exited", cleanup = "complete",
            evidence = {kind = "stop.before_start", detail = "explicit stop before Docker runner claim; no container dispatched"}})
    end
    if loaded.attempt.execution_state == "exited" then return succeed(loaded.attempt) end
    if loaded.attempt.execution_state == "starting" then return local_attempts.stop_attempt(loaded.attempt, "cooperative") end
    local stopping: types.ExecutionState? = nil
    if loaded.attempt.execution_state ~= "start_failed" and loaded.attempt.execution_state ~= "uncertain" then stopping = "stopping" end
    local requested = M.change(loaded.attempt.attempt_id, {execution = stopping, evidence = {kind = "docker.stop_requested", detail = "stop exact attempt container"}})
    if not requested.ok then
        local current, current_error = M.load({attempt_id = loaded.attempt.attempt_id}, true)
        if current and current.attempt.execution_state == "exited" then return succeed(current.attempt) end
        return requested
    end
    local found, find_error, absent = M.find(loaded)
    if find_error then return fail("UNAVAILABLE", find_error) end
    if not found then
        if absent and loaded.attempt.execution_state == "starting" then return requested end
        return fail("UNAVAILABLE", "container outcome is unknown")
    end
    if found.state == "exited" then return M.reconcile_loaded(loaded) end
    local object = bounds.object(value) or {}
    local grace = object.mode == "forced" and 0 or math.floor(loaded.request.timeouts.stop_grace_ms / 1000)
    local stopped_ok, stop_error = daemon.command({"docker", "--host", "unix:///var/run/docker.sock", "stop", "--time", tostring(grace), found.backend_ref})
    if not stopped_ok then return fail("UNAVAILABLE", stop_error or "Docker stop returned no result") end
    local stopped, verify_error = M.find(loaded)
    if not stopped or stopped.state ~= "exited" then return fail("UNAVAILABLE", verify_error or "Docker stop is unproven") end
    local_attempts.retire_gateway(loaded.attempt, "container stopped")
    return M.change(loaded.attempt.attempt_id, {execution = "exited", fields = {exit_source = "reconcile", exit_code = stopped.exit_code, placement_identity_json = json.encode(stopped)},
        evidence = {kind = "docker.stopped", detail = "container " .. stopped.backend_ref .. " is proven stopped"}})
end
function M.cleanup_preparers(value: unknown): Reply
    local loaded, load_error = M.load(value)
    if not loaded then return fail("DENIED", load_error or "attempt unavailable") end
    return M.cleanup_preparers_loaded(loaded)
end
function M.cleanup_preparers_loaded(loaded: Loaded): Reply
    if loaded.attempt.execution_state ~= "exited" and loaded.attempt.execution_state ~= "start_failed" then return fail("CONFLICT", "cleanup requires proven exit") end
    local found, find_error, absent = M.find(loaded)
    if find_error then return fail("UNAVAILABLE", find_error) end
    if not absent and (not found or (found.state ~= "stopped" and found.state ~= "exited")) then return fail("CONFLICT", "container remains live") end
    local cleaned, cleanup_error = workdir_preparers.cleanup(loaded.attempt)
    if not cleaned then return fail("UNAVAILABLE", cleanup_error or "workdir cleanup failed") end
    return M.change(loaded.attempt.attempt_id, {evidence = {kind = "workdir_preparers.settled", detail = "all planned preparers cleaned or retained after container exit"}})
end
function M.cleanup(value: unknown): Reply
    local loaded, load_error = M.load(value)
    if not loaded then return fail("DENIED", load_error or "attempt unavailable") end
    return M.cleanup_loaded(loaded)
end
function M.cleanup_loaded(loaded: Loaded): Reply
    if loaded.attempt.cleanup_state == "complete" then return succeed(loaded.attempt) end
    if loaded.attempt.execution_state ~= "exited" and loaded.attempt.execution_state ~= "start_failed" then return fail("CONFLICT", "cleanup requires proven container exit") end
    local found, find_error, absent = M.find(loaded)
    if find_error then return fail("UNAVAILABLE", find_error) end
    if found then
        if found.state ~= "stopped" and found.state ~= "exited" then return fail("CONFLICT", "owned container is still live") end
        local verified = M.change(loaded.attempt.attempt_id, {fields = {exit_source = "reconcile", exit_code = found.exit_code},
            evidence = {kind = "docker.exit_verified", detail = "exact container " .. found.backend_ref .. " is stopped before removal"}})
        if not verified.ok then return verified end
        local removed, remove_error = daemon.command({"docker", "--host", "unix:///var/run/docker.sock", "rm", found.backend_ref})
        if not removed then return fail("UNAVAILABLE", remove_error or "Docker removal returned no result") end
        local remaining, verify_error, missing = M.find(loaded)
        if verify_error or not missing then return fail("UNAVAILABLE", verify_error or "container removal is unproven") end
        local recorded = M.change(loaded.attempt.attempt_id, {evidence = {kind = "docker.removed", detail = "removed container " .. found.backend_ref .. " after exit evidence"}})
        if not recorded.ok then return recorded end
    elseif not absent then return fail("UNAVAILABLE", "container absence is unproven") end
    local preparers = M.cleanup_preparers_loaded(loaded)
    if not preparers.ok then return preparers end
    local home_key = bounds.id(loaded.row.home_key)
    if home_key then
        local home_error = homes.remove_attempt(home_key)
        if home_error then return fail("UNAVAILABLE", home_error) end
    end
    return M.change(loaded.attempt.attempt_id, {cleanup = "complete", evidence = {kind = "cleanup.complete", detail = "container absent; attempt scratch removed; provider session home retained"}})
end
M.SWEEP_INTERVAL_MS = 30000
M.SWEEPER_NAME = "bee.placement.docker.sweeper"
function M.sweep(): Reply
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "receipt store unavailable") end
    local rows, read_error = db:query("SELECT attempt_id FROM bee_placement_attempts WHERE placement_kind = 'docker' AND (execution_state IN ('starting', 'running', 'stopping', 'uncertain') OR (execution_state = 'exited' AND cleanup_state != 'complete')) ORDER BY updated_at LIMIT 64", {})
    db:release()
    if not rows or read_error then return fail("STORAGE", "read Docker attempts") end
    local count = 0
    for _, row in ipairs(rows) do
        local loaded = M.load({attempt_id = row.attempt_id}, true)
        if loaded then
            local result: Reply
            if loaded.attempt.execution_state == "exited" then
                local present = local_attempts.runner_present(loaded.row)
                if present == false then result = M.cleanup_loaded(loaded)
                else result = succeed(loaded.attempt) end
            else result = M.reconcile_loaded(loaded) end
            if result.ok then count = count + 1 end
        end
    end
    return succeed({reconciled = count})
end
function M.attach(value: unknown): Reply
    local loaded, load_error = M.load(value)
    if not loaded then return fail("DENIED", load_error or "attempt unavailable") end
    return local_attempts.attach(value)
end
function M.evidence(value: unknown): Reply
    local loaded, load_error = M.load(value)
    if not loaded then return fail("DENIED", load_error or "attempt unavailable") end
    return local_attempts.evidence(value)
end
function M.close_stdin(value: unknown): Reply
    local loaded, load_error = M.load(value)
    if not loaded then return fail("DENIED", load_error or "attempt unavailable") end
    return local_attempts.close_stdin(value)
end
function M.measure_executable(_value: unknown): Reply
    return fail("UNSUPPORTED_CAPABILITY", "Docker measures the runtime image; host executable bytes are not mounted")
end
function M.capabilities(value: unknown): Reply
    local report: {[string]: unknown} = {capability = "contained_tree", exit_observation = "independent", stdin_close = true,
        detail = "digest-pinned Docker route; container stop and absence by exact container ID",
        executable_measurement = {streaming = false, read_only_volume = true, detail = "immutable runtime image"},
        resource_authority = "granted", delegated_resource_grants = true, revocation_enforcement = "container_stop",
        credential_broker = true, credential_projections = {"file", "environment"}}
    local request = bounds.object(value)
    if request and request.placement_profile_ref ~= nil then
        if bounds.fields(request, {"placement_profile_ref", "runtime_name", "probe_argv"}) then return fail("INVALID", "invalid Docker readiness request") end
        local ref, runtime_name = bounds.id(request.placement_profile_ref), bounds.id(request.runtime_name)
        if not ref or not runtime_name or not runtime_name:match("^[A-Za-z0-9_.%-]+$") then return fail("INVALID", "Docker readiness requires a profile and runtime name") end
        local pinned = registry.snapshot()
        local selected = pinned and profiles.resolve(pinned, ref) or nil
        if not selected or selected.profile.placement_binding ~= spec_codec.BINDING then return fail("INVALID", "profile does not select Docker") end
        local network = selected.profile.network
        local present = network == "none"
        if network and network ~= "none" then
            local observed, network_error = daemon.inspect("network", network)
            if network_error then return fail("UNAVAILABLE", network_error) end
            present = observed ~= nil
        end
        local config_entry = registry.get("bee.placement.docker.env:environment_configuration")
        local config_record = config_entry and bounds.object(config_entry.data)
        local config = config_record and bounds.object(config_record.value)
        local provisionable = config ~= nil and config.network == network and not environment.revoked()
        report.network_readiness = {present = present, provisionable = provisionable, reason = present and "host-selected Docker network is available"
            or "host-selected Docker network is missing; admit its restricted gateway interface before use: " .. (network or "")}
        local image_ref = selected.profile.image_ref
        if selected.profile.image_recipe_ref then
            local readiness, readiness_error = image_service.readiness(selected.profile.image_recipe_ref, runtime_name)
            if not readiness then return fail("UNAVAILABLE", readiness_error or "runtime artifact discovery unavailable") end
            report.image_readiness = readiness
            local image_ref = bounds.line(readiness.image_ref, 128)
            if request.probe_argv ~= nil then
                if not image_ref then return fail("UNAVAILABLE", "Docker image is not cached; launch once to build it before option help is available") end
                local output, err = runtime_probe.run(image_ref, runtime_name, request.probe_argv)
                if not output then return fail("UNAVAILABLE", err or "Docker help probe failed") end
                report.probe_output = output
            end
            return succeed(report)
        end
        if not image_ref then return fail("INVALID", "Docker profile has no image") end
        local image, inspect_error = daemon.inspect("image", image_ref)
        if inspect_error then return fail("UNAVAILABLE", inspect_error) end
        local object = bounds.object(image)
        local config = object and bounds.object(object.Config) or nil
        local labels = config and bounds.object(config.Labels) or nil
        local digest = labels and bounds.line(labels["bee.runtime." .. runtime_name], 64) or nil
        local immutable = object and bounds.line(object.Id, 128)
        if request.probe_argv ~= nil then
            if not immutable or not digest then return fail("UNAVAILABLE", "Docker image is missing or has no runtime evidence") end
            local output, err = runtime_probe.run(immutable, runtime_name, request.probe_argv)
            if not output then return fail("UNAVAILABLE", err or "Docker help probe failed") end
            report.probe_output = output
        end
        report.image_readiness = {image_ref = immutable, image_digest = immutable, present = object ~= nil, runtime_present = digest ~= nil and #digest == 64 and digest:match("^[0-9a-f]+$") ~= nil,
            os = object and bounds.line(object.Os, 32) or nil, arch = object and bounds.line(object.Architecture, 32) or nil,
            reason = object and "runtime image is installed" or "Docker runtime image is missing or unavailable"}
    end
    return succeed(report)
end
return M
