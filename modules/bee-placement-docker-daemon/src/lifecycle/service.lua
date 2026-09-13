-- MIT. The Docker placement owner. Durable intent and lifecycle state remain
-- in the native placement store; this module owns only the Docker execution
-- path selected by the host binding.
local security = require("security")
local bounds = require("bounds")
local json = require("json")
local process = require("process")
local hash = require("hash")
local canonical = require("canonical")
local registry = require("registry")
local resolver = require("resolver")
local placement_resolver = require("placement_resolver")
local request_codec = require("request")
local types = require("types")
local store = require("store")
local homes = require("homes")
local native = require("native_service")
local materialization = require("materialization")
local configuration_protocol = require("configuration_protocol")
local docker_configuration = require("docker_configuration")
local daemon = require("daemon")
local resources = require("resources")
local M = {}
M.BINDING = "bee.placement.docker:binding"
M.RECONCILE_TARGET = "bee.placement.docker:reconcile_internal"
M.SWEEP_BOUND = 64
type Object = {[string]: unknown}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
type Row = store.Row
type Identity = {container_id: string, image_id: string, apparmor: string?, started_at: string?, labels: {[string]: string}}
type Spec = Object
type Observation = {container_id: string, image_id: string, started_at: string?, state: string, exit_code: integer?, labels: {[string]: string}}

local function fail(code: string, message: string): Reply return {ok = false, error = {code = code, message = message}, value = nil} end
local function succeed(value: unknown): Reply return {ok = true, error = nil, value = value} end
local function actor(): string? local a = security.actor(); return a and bounds.id(a:id()) or nil end
local function object(value: unknown, name: string): (Object?, Reply?)
    local result = bounds.object(value)
    if not result then return nil, fail("INVALID", name .. " must be an object") end
    return result, nil
end
local function id(value: unknown, name: string): (string?, Reply?)
    local result = bounds.id(value)
    if not result then return nil, fail("INVALID", name .. " is not an identifier") end
    return result, nil
end
local function owner(attempt: types.Attempt): Reply?
    local current = actor()
    if not current then return fail("UNAUTHENTICATED", "no actor") end
    if current ~= attempt.owner_id then return fail("FORBIDDEN", "the attempt belongs to another owner") end
    return nil
end
local function named(value: unknown, name: string): (string?, Reply?)
    local request, invalid = object(value, name)
    if not request then return nil, invalid end
    local unknown = bounds.fields(request, {"attempt_id"})
    if unknown then return nil, fail("INVALID", unknown) end
    return id(request.attempt_id, "attempt_id")
end
local function load(value: unknown, require_owner: boolean?): (types.Attempt?, Row?, Reply?)
    local attempt_id, invalid = id(value, "attempt_id")
    if not attempt_id then return nil, nil, invalid end
    local db, open_error = store.open()
    if not db then return nil, nil, fail("STORAGE", open_error or "open placement store") end
    local row, row_error = store.row(db, attempt_id :: string)
    local attempt = row and store.attempt(db, attempt_id :: string) or nil
    db:release()
    if row_error then return nil, nil, fail("STORAGE", row_error) end
    if not row or not attempt then return nil, nil, fail("NOT_FOUND", "attempt is not recorded") end
    if row.placement_kind ~= "docker" then return nil, nil, fail("DENIED", "Docker placement cannot operate a native attempt") end
    if require_owner ~= false then
        local refused = owner(attempt)
        if refused then return nil, nil, refused end
    end
    return attempt, row, nil
end
local function transition(attempt_id: string, update: store.Update): Reply
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local result = store.transition(db, attempt_id, update)
    db:release()
    if not result.ok then return fail(result.code or "STORAGE", result.message or "transition failed") end
    return succeed(result.attempt)
end
local function decode_json(value: unknown, name: string): (Object?, Reply?)
    if type(value) ~= "string" then return nil, fail("STORAGE", name .. " is missing") end
    local decoded, decode_error = json.decode(value)
    local result = bounds.object(decoded)
    if decode_error or not result then return nil, fail("STORAGE", name .. " is unreadable") end
    return result, nil
end
local function identity(row: Row): (Identity?, Reply?)
    if row.placement_identity_json == nil then return nil, nil end
    local raw, refused = decode_json(row.placement_identity_json, "Docker identity")
    if not raw then return nil, refused end
    local container_id = bounds.text(raw.container_id, 64)
    local image_id = bounds.text(raw.image_id, 71)
    if not container_id or #container_id ~= 64 or not container_id:match("^[0-9a-f]+$")
        or not image_id or #image_id ~= 71 or not image_id:match("^sha256:[0-9a-f]+$") then
        return nil, fail("STORAGE", "Docker identity is malformed")
    end
    local labels = bounds.object(raw.labels)
    if not labels then return nil, fail("STORAGE", "Docker identity has no labels") end
    local selected: {[string]: string} = {}
    for key, value in pairs(labels) do
        if type(key) ~= "string" or type(value) ~= "string" then return nil, fail("STORAGE", "Docker identity labels are malformed") end
        selected[key] = value
    end
    local apparmor: string? = nil
    if raw.apparmor ~= nil then apparmor = bounds.text(raw.apparmor, 128) end
    local started_at: string? = nil
    if raw.started_at ~= nil then started_at = bounds.text(raw.started_at, 64) end
    return {container_id = container_id :: string, image_id = image_id :: string, apparmor = apparmor, started_at = started_at, labels = selected}, nil
end
local function encode(value: unknown, name: string): (string?, Reply?)
    local encoded, encode_error = json.encode(value)
    if not encoded then return nil, fail("INVALID", name .. " is not encodable") end
    return encoded, nil
end
local function policy_docker(pinned: registry.Snapshot, request: types.LaunchRequest): (Object?, Reply?)
    local entry = resolver.entry(pinned, request.policy_ref)
    local data = entry and bounds.object(entry.data) or nil
    if not data then return nil, fail("DENIED", "policy_ref is not a host launch policy") end
    local selected = bounds.object(data.docker)
    if not selected then return nil, fail("DENIED", "Docker policy has no host-selected docker specification") end
    return selected, nil
end
local function working_directory(request: types.LaunchRequest): (string?, Reply?)
    if not request.launch.working_directory_ref then return native.configured_home(request) end
    for _, grant in ipairs(request.resources) do
        if grant.name == request.launch.working_directory_ref then
            local root, root_error = resources.directory(grant.root_ref)
            if not root then return nil, fail("DENIED", root_error or "resource root") end
            return grant.subpath == "" and root or root .. "/" .. grant.subpath, nil
        end
    end
    return nil, fail("DENIED", "working directory grant is missing")
end
local function labels(request: types.LaunchRequest, digest: string, image: string): {[string]: string}
    return {["bee.actor_ref"] = request.owner_id, ["bee.revision_digest"] = request.profile_digest,
        ["bee.attempt_id"] = request.attempt_id, ["bee.request_digest"] = digest,
        ["bee.lease_fence"] = tostring(request.owner_incarnation), ["bee.image_digest"] = image}
end
local function spec_from(policy: Object, request: types.LaunchRequest, digest: string, home: string, work: string, delivery: types.ConfigurationDelivery): (Spec?, Reply?)
    local image = policy.image or policy.image_digest
    local command: {string} = {request.launch.executable}
    for _, item in ipairs(delivery.arguments) do command[#command + 1] = item end
    for _, item in ipairs(request.launch.argv) do command[#command + 1] = item end
    local home_target = policy.home_target or "/home/bee"
    local container_work = work == home and home_target or nil
    local mounts = type(policy.mounts) == "table" and policy.mounts :: {unknown} or {}
    local function under(child: string, parent: string): boolean return child == parent or child:sub(1, #parent + 1) == parent .. "/" end
    if not container_work then
        for _, item in ipairs(mounts) do
            local mount = bounds.object(item)
            local source = mount and bounds.text(mount.source, 4096)
            local target = mount and bounds.text(mount.target, 4096)
            if source and target and under(work, source) then
                container_work = target .. work:sub(#source + 1)
                break
            end
        end
    end
    if not container_work then return nil, fail("DENIED", "working directory is outside Docker mount targets") end
    local spec: Spec = {image = image, user = policy.user, network = policy.network, apparmor = policy.apparmor,
        memory = policy.memory, nano_cpus = policy.nano_cpus, pids_limit = policy.pids_limit, command = command,
        home_source = home, home_target = home_target, mounts = policy.mounts,
        working_directory = container_work, labels = labels(request, digest, tostring(image))}
    local checked, check_error = docker_configuration.build(spec)
    if not checked then return nil, fail("DENIED", check_error or "Docker specification is not admitted") end
    return spec, nil
end
local function expected(identity_value: Identity): Object
    return {container_id = identity_value.container_id, image_id = identity_value.image_id, apparmor = identity_value.apparmor,
        started_at = identity_value.started_at, labels = identity_value.labels}
end
local function observed_identity(observed: Observation, prior: Identity?, selected_apparmor: string?): Identity
    return {container_id = observed.container_id, image_id = observed.image_id, apparmor = prior and prior.apparmor or selected_apparmor,
        started_at = observed.started_at, labels = observed.labels}
end
local function daemon_failure(fault: {[string]: unknown}?, fallback: string): Reply
    local kind = fault and fault.kind
    local message = fault and fault.message or fallback
    if kind == "mismatch" then return fail("CONFLICT", tostring(message)) end
    if kind == "absent" then return fail("NOT_FOUND", tostring(message)) end
    return fail("UNAVAILABLE", tostring(message))
end
local function container_name(attempt: types.Attempt, row: Row): (string?, Reply?)
    local encoded, encode_error = canonical.encode({owner_id = attempt.owner_id, attempt_id = attempt.attempt_id, request_digest = row.request_digest})
    if not encoded then return nil, fail("INVALID", encode_error or "container name input") end
    local digest, digest_error = hash.sha256(encoded :: string)
    if not digest then return nil, fail("INTERNAL", tostring(digest_error or "container name digest")) end
    return "bee-" .. digest, nil
end
-- A cleanup receipt covers the temporary materialization as well as Docker.
-- Session homes are distinct and remain under the shared session claim.
local function complete_cleanup(attempt_id: string, detail: string): Reply
    local attempt, row, denied = load(attempt_id)
    if not attempt or not row then return denied :: Reply end
    if attempt.execution_state ~= "exited" then return fail("CONFLICT", "cleanup requires confirmed execution completion") end
    if row.home_key ~= nil and row.home_key ~= "" then
        local key = bounds.text(row.home_key, 32)
        if type(key) ~= "string" then return fail("STORAGE", "attempt home identity is malformed") end
        if #key ~= 32 or not key:match("^[0-9a-f]+$") then return fail("STORAGE", "attempt home identity is malformed") end
        local removal_error = homes.remove_attempt(key)
        if removal_error then
            return transition(attempt_id, {cleanup = "uncertain", evidence = {kind = "docker.cleanup.home_failed", detail = removal_error}})
        end
    end
    return transition(attempt_id, {expected_execution = "exited", cleanup = "complete",
        evidence = {kind = "docker.cleanup.complete", detail = detail .. "; temporary attempt home removed"}})
end
local function cancel_without_container(attempt_id: string): Reply
    local attempt, _, denied = load(attempt_id)
    if not attempt then return denied :: Reply end
    if attempt.execution_state == "stopping" then
        local stopped = transition(attempt_id, {expected_execution = "stopping", execution = "exited",
            evidence = {kind = "docker.stop.before_create", detail = "stop intent won before Docker container creation"}})
        if not stopped.ok then return stopped end
        return complete_cleanup(attempt_id, "stop confirmed before container creation")
    end
    return succeed(attempt)
end
local function cancel_container(attempt_id: string, saved: Identity): Reply
    local stopped, stop_error = daemon.stop({container_id = saved.container_id, expected = expected(saved), timeout_seconds = 10})
    if not stopped and (not stop_error or stop_error.kind ~= "absent") then
        transition(attempt_id, {evidence = {kind = "docker.cancel.stop_uncertain", detail = stop_error and stop_error.message or "Docker stop was not confirmed"}})
        return fail("UNCERTAIN", stop_error and stop_error.message or "Docker stop was not confirmed")
    end
    local removed, remove_error = daemon.remove({container_id = saved.container_id, expected = expected(saved)})
    if not removed then
        transition(attempt_id, {evidence = {kind = "docker.cancel.remove_uncertain", detail = remove_error and remove_error.message or "Docker removal was not confirmed"}})
        return fail("UNCERTAIN", remove_error and remove_error.message or "Docker removal was not confirmed")
    end
    local current, _, denied = load(attempt_id)
    if not current then return denied :: Reply end
    if current.execution_state == "stopping" then
        local stopped = transition(attempt_id, {expected_execution = "stopping", execution = "exited",
            evidence = {kind = "docker.stop.canceled_start", detail = "container stopped and removed after stop intent"}})
        if not stopped.ok then return stopped end
        return complete_cleanup(attempt_id, "canceled container absence confirmed")
    end
    if current.execution_state == "exited" and current.cleanup_state ~= "complete" then
        return complete_cleanup(attempt_id, "canceled container absence confirmed")
    end
    return succeed(current)
end

function M.prepare(value: unknown): Reply
    local request, decode_error = request_codec.decode(value)
    if not request then return fail("INVALID", decode_error or "invalid launch request") end
    if not request.placement_binding_ref then return fail("DENIED", "Docker placement requires its selected binding") end
    local current = actor()
    if not current then return fail("UNAUTHENTICATED", "no actor") end
    if current ~= request.owner_id then return fail("FORBIDDEN", "owner_id is not the caller") end
    local conflict = native.environment_conflict(request)
    if conflict then return fail("INVALID", conflict) end
    if request.launch.stdin_eof == true then return fail("UNSUPPORTED_CAPABILITY", "Docker placement cannot close stdin") end
    local digest, digest_error = request_codec.digest(request)
    if not digest then return fail("INVALID", digest_error or "request is not measurable") end
    local pinned, pin_error = resolver.pin()
    if not pinned then return fail("UNAVAILABLE", pin_error or "pin registry") end
    local selected, placement_error = placement_resolver.resolve(pinned, request.placement_binding_ref)
    if not selected or selected.placement_kind ~= "docker" then return fail("DENIED", placement_error or "selected binding is not Docker") end
    if request.placement_binding_digest ~= selected.binding_digest then return fail("CONFLICT", "Docker placement binding changed since admission") end
    local admitted, resources_refused = native.admit_resources(request)
    if not admitted then return resources_refused :: Reply end
    for _, projection_id in ipairs(request.projections) do
        local refused = native.check_projection(request, projection_id)
        if refused then return refused end
    end
    local configuration, target, configuration_error = native.configuration_input(pinned, request, true)
    if not configuration or not target then return fail("DENIED", configuration_error or "Docker configuration inputs unavailable") end
    local selected_digest, selected_error = configuration_protocol.digest(configuration, target)
    if request.configuration_digest and request.configuration_digest ~= selected_digest then return fail("CONFLICT", "host configuration inputs changed") end
    if not request.configuration_digest and selected_digest then
        if configuration.provider_ref or configuration.gateway or configuration.instructions or configuration.instruction_builder then
            return fail("DENIED", "configured launches require the selected configuration digest")
        end
    end
    local home, home_error = native.configured_home(request)
    if not home then return fail("UNAVAILABLE", home_error or "configuration home unavailable") end
    local policy, policy_error = policy_docker(pinned, request)
    if not policy then return policy_error :: Reply end
    -- Render paths as the harness sees them. Delivery files remain relative
    -- and the shared materializer writes them into the private host home.
    local container_home = bounds.text(policy.home_target or "/home/bee", 4096)
    if not container_home then return fail("DENIED", "Docker home target is invalid") end
    configuration.home_directory = container_home
    local delivery, delivery_error = configuration_protocol.call(target, configuration)
    if not delivery then return fail("DENIED", delivery_error or "configuration rendering failed") end
    local work, work_error = working_directory(request)
    if not work then return work_error :: Reply end
    local spec, spec_error = spec_from(policy, request, digest, home :: string, work :: string, delivery :: types.ConfigurationDelivery)
    if not spec then return spec_error :: Reply end
    local capabilities, capability_error = daemon.capabilities()
    if not capabilities then return daemon_failure(capability_error, "Docker host capabilities are unavailable") end
    if not capabilities.linux or not capabilities.seccomp or not capabilities.memory_limit
        or not capabilities.pids_limit or not capabilities.cpu_quota then
        return fail("UNAVAILABLE", "Docker host does not support the required sandbox limits")
    end
    if spec.apparmor ~= nil and not capabilities.apparmor then
        return fail("UNAVAILABLE", "Docker host does not support the required AppArmor profile")
    end
    local spec_json, spec_encode_error = encode(spec, "Docker specification")
    if not spec_json then return spec_encode_error :: Reply end
    local stored: Object = {}
    for key, item in pairs(request) do stored[key] = item end
    stored.delivery = delivery
    local encoded, encoded_error = encode(stored, "request")
    if not encoded then return encoded_error :: Reply end
    local grants_json = #admitted > 0 and json.encode(admitted) or nil
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local result = store.intend(db, request, digest, encoded :: string, {capability = "contained_tree", exit_observation = "independent"}, grants_json,
        {kind = "docker", spec_json = spec_json :: string, identity_json = nil})
    db:release()
    if not result.ok then return fail(result.code or "STORAGE", result.message or "record intent") end
    return succeed(result.attempt)
end

function M.start(value: unknown): Reply
    local request, invalid = object(value, "start")
    if not request then return invalid :: Reply end
    local unknown = bounds.fields(request, {"attempt_id", "gateway_binding"})
    if unknown then return fail("INVALID", unknown) end
    if request.gateway_binding ~= nil and not bounds.id(request.gateway_binding) then return fail("INVALID", "gateway_binding is not an identifier") end
    local attempt, row, denied = load(request.attempt_id)
    if not attempt then return denied :: Reply end
    if attempt.execution_state == "running" then return succeed(attempt) end
    if attempt.execution_state == "exited" then return succeed(attempt) end
    if attempt.execution_state ~= "intended" then return fail("UNCERTAIN", "Docker start requires reconciliation of " .. attempt.execution_state) end
    local stored, stored_error = store.request(row :: Row)
    if not stored then return fail("STORAGE", stored_error or "attempt request unreadable") end
    local spec, spec_error = decode_json(row.placement_spec_json, "Docker specification")
    if not spec then return spec_error :: Reply end
    local checked, build_error = docker_configuration.build(spec)
    if not checked then return fail("STORAGE", build_error or "frozen Docker specification is invalid") end
    local requested = transition(attempt.attempt_id, {expected_execution = "intended", execution = "starting", fields = {runner_pid = process.pid()}, evidence = {kind = "docker.starting", detail = "Docker lifecycle owner claimed attempt"}})
    if not requested.ok then return requested end
    local current, current_row, current_denied = load(attempt.attempt_id)
    if not current then return current_denied :: Reply end
    local gateway_binding: string? = request.gateway_binding :: string?
    local materialization_key, auth_denied = native.authorize_materialization(current, current_row :: Row, stored, gateway_binding)
    if auth_denied then transition(attempt.attempt_id, {execution = "exited", fields = {runner_pid = ""}, evidence = {kind = "docker.authorization_failed", detail = auth_denied.error and auth_denied.error.message or "authorization failed"}}); return auth_denied end
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local prepared, prep_error = materialization.prepare(db, stored, attempt.attempt_id, current.attachment_generation, gateway_binding, materialization_key)
    db:release()
    if not prepared then
        local latest, _, latest_denied = load(attempt.attempt_id)
        if latest and latest.execution_state == "stopping" then return cancel_without_container(attempt.attempt_id) end
        if latest_denied then return latest_denied end
        return fail("DENIED", prep_error or "Docker materialization failed")
    end
    -- HOME is owned by placement, not an arbitrary environment substitution.
    -- Check the materializer's physical home before selecting its mounted path.
    if prepared.environment.HOME ~= spec.home_source then return fail("DENIED", "materialized home differs from the admitted Docker source") end
    local container_home = bounds.text(spec.home_target, 4096)
    if not container_home then return fail("STORAGE", "frozen Docker home target is invalid") end
    prepared.environment.HOME = container_home
    local config, config_error = docker_configuration.build(spec, prepared.environment)
    if not config then return fail("DENIED", config_error or "Docker configuration failed") end
    local ready, _, ready_denied = load(attempt.attempt_id)
    if not ready then return ready_denied :: Reply end
    if ready.execution_state ~= "starting" then return cancel_without_container(attempt.attempt_id) end
    local name, name_error = container_name(attempt, row :: Row)
    if not name then return name_error :: Reply end
    local create_expected = {image_id = spec.image, apparmor = spec.apparmor, labels = spec.labels}
    local observed, daemon_error = daemon.create({name = name, config = config, expected = create_expected})
    if not observed then
        -- A create reply can be lost after Docker committed the container.
        -- Recovery is an exact-name lookup and inspection; there is no retry
        -- create path, so transport uncertainty cannot duplicate a container.
        observed, daemon_error = daemon.recover_create({name = name, expected = create_expected})
    end
    if not observed then
        transition(attempt.attempt_id, {fields = {runner_pid = ""}, evidence = {kind = "docker.create_uncertain", detail = daemon_error and daemon_error.message or "Docker create was not confirmed"}})
        return fail("UNCERTAIN", daemon_error and daemon_error.message or "Docker create was not confirmed")
    end
    local first_identity = observed_identity(observed :: Observation, nil, bounds.text(spec.apparmor, 128))
    local identity_json, identity_error = encode(first_identity, "Docker identity")
    if not identity_json then return identity_error :: Reply end
    local created = transition(attempt.attempt_id, {expected_execution = "starting", fields = {placement_identity_json = identity_json, runner_pid = ""}, evidence = {kind = "docker.created", detail = "container identity confirmed before start"}})
    if not created.ok then return cancel_container(attempt.attempt_id, first_identity) end
    if observed.state == "exited" then return transition(attempt.attempt_id, {execution = "exited", evidence = {kind = "docker.exited", detail = "container was exited during create recovery"}}) end
    local before_start, _, before_start_denied = load(attempt.attempt_id)
    if not before_start then return before_start_denied :: Reply end
    if before_start.execution_state ~= "starting" then return cancel_container(attempt.attempt_id, first_identity) end
    local start_check = transition(attempt.attempt_id, {expected_execution = "starting",
        evidence = {kind = "docker.start.checked", detail = "start remains admitted; a concurrent stop requires confirmed compensation"}})
    if not start_check.ok then return cancel_container(attempt.attempt_id, first_identity) end
    local started, start_error = daemon.start({container_id = first_identity.container_id, expected = expected(first_identity)})
    if not started then
        local latest, _, latest_denied = load(attempt.attempt_id)
        if latest and (latest.execution_state == "stopping" or latest.execution_state == "exited") then return cancel_container(attempt.attempt_id, first_identity) end
        if latest_denied then return latest_denied end
        transition(attempt.attempt_id, {evidence = {kind = "docker.start_uncertain", detail = start_error and start_error.message or "Docker start was not confirmed"}})
        return fail("UNCERTAIN", start_error and start_error.message or "Docker start was not confirmed")
    end
    local final_identity = observed_identity(started :: Observation, first_identity)
    local final_json, final_error = encode(final_identity, "Docker identity")
    if not final_json then return final_error :: Reply end
    local finished = transition(attempt.attempt_id, {expected_execution = "starting", execution = "running", fields = {placement_identity_json = final_json, runner_pid = ""}, evidence = {kind = "docker.started", detail = "container running identity confirmed"}})
    if not finished.ok then return cancel_container(attempt.attempt_id, final_identity) end
    return finished
end

function M.status(value: unknown): Reply
    local attempt_id, invalid = named(value, "status")
    if not attempt_id then return invalid :: Reply end
    local attempt, row, denied = load(attempt_id)
    if not attempt then return denied :: Reply end
    local saved, identity_error = identity(row :: Row)
    if identity_error then return identity_error :: Reply end
    if not saved then return succeed({attempt = attempt, liveness = {observed = false, alive = nil, detail = "no Docker identity recorded"}}) end
    local observed, daemon_error = daemon.inspect({container_id = saved.container_id, expected = expected(saved)})
    if not observed then return daemon_failure(daemon_error, "Docker inspection failed") end
    return succeed({attempt = attempt, observation = observed, liveness = {observed = true, alive = observed.state == "running", detail = "Docker identity confirmed"}})
end

function M.stop(value: unknown): Reply
    local request, invalid = object(value, "stop")
    if not request then return invalid :: Reply end
    local unknown = bounds.fields(request, {"attempt_id", "mode"})
    if unknown then return fail("INVALID", unknown) end
    if request.mode ~= nil and request.mode ~= "cooperative" and request.mode ~= "forced" then return fail("INVALID", "mode must be cooperative or forced") end
    local attempt, row, denied = load(request.attempt_id)
    if not attempt then return denied :: Reply end
    if attempt.execution_state == "intended" then return transition(attempt.attempt_id, {expected_execution = "intended", execution = "exited", cleanup = "complete", evidence = {kind = "docker.stop.before_start", detail = "no container was created"}}) end
    if attempt.execution_state == "exited" then return succeed(attempt) end
    local saved, identity_error = identity(row :: Row)
    if identity_error then return identity_error :: Reply end
    if not saved then
        if attempt.execution_state == "starting" then
            return transition(attempt.attempt_id, {expected_execution = "starting", execution = "stopping", evidence = {kind = "docker.stop.requested", detail = "stop intent recorded while Docker creation is in progress"}})
        end
        if attempt.execution_state == "stopping" then return succeed(attempt) end
        return transition(attempt.attempt_id, {execution = "stopping", evidence = {kind = "docker.stop.unproven", detail = "no container identity recorded"}})
    end
    if attempt.execution_state ~= "stopping" then
        local requested = transition(attempt.attempt_id, {expected_execution = attempt.execution_state, execution = "stopping", evidence = {kind = "docker.stop.requested", detail = "daemon stop requires confirmed observation"}})
        if not requested.ok then return requested end
    end
    local was_starting = attempt.execution_state == "starting"
    local stopped, stop_error = daemon.stop({container_id = saved.container_id, expected = expected(saved), timeout_seconds = 10})
    if not stopped then
        transition(attempt.attempt_id, {execution = "stopping", evidence = {kind = "docker.stop.uncertain", detail = stop_error and stop_error.message or "Docker stop was not confirmed"}})
        return fail("UNCERTAIN", stop_error and stop_error.message or "Docker stop was not confirmed")
    end
    if was_starting and stopped.state == "created" then
        local removed, remove_error = daemon.remove({container_id = saved.container_id, expected = expected(saved)})
        if not removed then
            transition(attempt.attempt_id, {execution = "stopping", evidence = {kind = "docker.stop.remove_uncertain", detail = remove_error and remove_error.message or "Docker removal was not confirmed"}})
            return fail("UNCERTAIN", remove_error and remove_error.message or "Docker removal was not confirmed")
        end
        local stopped = transition(attempt.attempt_id, {execution = "exited", evidence = {kind = "docker.stop.before_start", detail = "created container removed before Docker start"}})
        if not stopped.ok then return stopped end
        return complete_cleanup(attempt.attempt_id, "created container removal confirmed")
    end
    local final = observed_identity(stopped :: Observation, saved)
    local encoded, encode_error = encode(final, "Docker identity")
    if not encoded then return encode_error :: Reply end
    return transition(attempt.attempt_id, {execution = "exited", fields = {placement_identity_json = encoded}, evidence = {kind = "docker.exited", detail = "daemon confirmed container exit"}})
end

function M.reconcile(value: unknown): Reply
    local attempt_id, invalid = named(value, "reconcile")
    if not attempt_id then return invalid :: Reply end
    local attempt, row, denied = load(attempt_id)
    if not attempt then return denied :: Reply end
    return M.reconcile_attempt(attempt, row :: Row)
end
-- An unavailable observation is evidence, not proof that execution changed.
-- Keep live/stopping attempts eligible for supervision and an explicit stop.
local function unobserved(attempt: types.Attempt, kind: string, detail: string): Reply
    local recorded = transition(attempt.attempt_id, {expected_execution = attempt.execution_state,
        evidence = {kind = kind, detail = detail}})
    if not recorded.ok then return recorded end
    return fail("UNCERTAIN", detail)
end

function M.reconcile_attempt(attempt: types.Attempt, row: Row): Reply
    if attempt.execution_state == "intended" or attempt.execution_state == "exited" then return succeed(attempt) end
    local saved, identity_error = identity(row)
    if identity_error then return identity_error :: Reply end
    if not saved then return unobserved(attempt, "docker.reconcile.unidentified", "no Docker identity recorded; execution and stop intent remain unconfirmed") end
    local observed, daemon_error = daemon.inspect({container_id = saved.container_id, expected = expected(saved)})
    if not observed then
        if daemon_error and daemon_error.kind == "absent" then return unobserved(attempt, "docker.reconcile.absent", "container absence cannot prove prior exit") end
        return unobserved(attempt, "docker.reconcile.uncertain", daemon_error and daemon_error.message or "Docker inspection failed")
    end
    local updated = observed_identity(observed :: Observation, saved)
    local encoded, encode_error = encode(updated, "Docker identity")
    if not encoded then return encode_error :: Reply end
    if observed.state == "running" then
        return transition(attempt.attempt_id, {expected_execution = attempt.execution_state, fields = {placement_identity_json = encoded}, evidence = {kind = "docker.reconcile.alive", detail = "container running identity confirmed"}})
    end
    if observed.state == "exited" then return transition(attempt.attempt_id, {expected_execution = attempt.execution_state, execution = "exited", fields = {placement_identity_json = encoded}, evidence = {kind = "docker.reconcile.exited", detail = "daemon confirmed container exit"}}) end
    return transition(attempt.attempt_id, {expected_execution = attempt.execution_state, evidence = {kind = "docker.reconcile.created", detail = "container exists but has not started"}})
end

function M.cleanup(value: unknown): Reply
    local attempt_id, invalid = named(value, "cleanup")
    if not attempt_id then return invalid :: Reply end
    local attempt, row, denied = load(attempt_id)
    if not attempt then return denied :: Reply end
    if attempt.cleanup_state == "complete" then return succeed(attempt) end
    if attempt.execution_state ~= "exited" then return fail("CONFLICT", "cleanup needs a proven Docker exit") end
    local saved, identity_error = identity(row :: Row)
    if identity_error then return identity_error :: Reply end
    if saved then
        local removed, remove_error = daemon.remove({container_id = saved.container_id, expected = expected(saved)})
        if not removed then return fail("UNCERTAIN", remove_error and remove_error.message or "Docker absence was not confirmed") end
    end
    return complete_cleanup(attempt.attempt_id, saved and "daemon confirmed container absence" or "no container was created")
end

function M.container_identity(value: unknown): Reply
    local request, invalid = object(value, "container_identity")
    if not request then return invalid :: Reply end
    local unknown = bounds.fields(request, {"attempt_id", "recipient", "generation"})
    if unknown then return fail("INVALID", unknown) end
    local recipient = bounds.text(request.recipient, 256)
    local generation = bounds.integer(request.generation)
    if not recipient or recipient == "" or not generation or generation < 1 then
        return fail("INVALID", "container_identity requires recipient and generation")
    end
    local attempt_id, id_error = id(request.attempt_id, "attempt_id")
    if not attempt_id then return id_error :: Reply end
    local attempt, row, denied = load(attempt_id)
    if not attempt then return denied :: Reply end
    if attempt.execution_state ~= "running" then return fail("CONFLICT", "Docker container is not recorded running") end
    if row.recipient ~= recipient or row.attachment_generation ~= generation then return fail("FORBIDDEN", "attachment generation is not admitted") end
    local saved, identity_error = identity(row :: Row)
    if identity_error then return identity_error :: Reply end
    if not saved or not saved.started_at then return fail("CONFLICT", "Docker container has no recorded start identity") end
    local observed, daemon_error = daemon.inspect({container_id = saved.container_id, expected = expected(saved)})
    if not observed then return daemon_failure(daemon_error, "Docker inspection failed") end
    if observed.state ~= "running" then return fail("CONFLICT", "Docker container is not running") end
    if observed.started_at ~= saved.started_at then return fail("CONFLICT", "Docker execution start identity changed") end
    return succeed({container_id = saved.container_id, image_id = saved.image_id, started_at = saved.started_at, labels = saved.labels})
end

function M.evidence(value: unknown): Reply
    local request, invalid = object(value, "evidence")
    if not request then return invalid :: Reply end
    local unknown = bounds.fields(request, {"attempt_id", "after", "limit"})
    if unknown then return fail("INVALID", unknown) end
    local attempt, _, denied = load(request.attempt_id)
    if not attempt then return denied :: Reply end
    local after = bounds.integer(request.after == nil and 0 or request.after)
    local limit = bounds.integer(request.limit == nil and store.MAX_EVIDENCE_PAGE or request.limit)
    if not after or after < 0 or not limit then return fail("INVALID", "evidence page bounds are invalid") end
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local page, page_error = store.evidence(db, attempt.attempt_id, after, limit)
    db:release()
    if not page then return fail("STORAGE", page_error or "read evidence") end
    return succeed(page)
end
function M.attach(value: unknown): Reply
    local request, invalid = object(value, "attach")
    if not request then return invalid :: Reply end
    local unknown = bounds.fields(request, {"attempt_id", "recipient", "generation"})
    if unknown then return fail("INVALID", unknown) end
    local recipient = bounds.text(request.recipient, 256)
    local generation = bounds.integer(request.generation)
    if not recipient or recipient == "" then return fail("INVALID", "recipient must be a process address") end
    if not generation or generation < 1 then return fail("INVALID", "generation must be positive") end
    local attempt, _, denied = load(request.attempt_id)
    if not attempt then return denied :: Reply end
    if generation <= attempt.attachment_generation then return fail("CONFLICT", "generation is not newer than the current attachment") end
    return transition(attempt.attempt_id, {fields = {recipient = recipient, attachment_generation = generation}, evidence = {kind = "docker.attach", detail = "generation " .. tostring(generation)}})
end
function M.capabilities(): Reply
    local capabilities, capability_error = daemon.capabilities()
    if not capabilities then return daemon_failure(capability_error, "Docker host capabilities are unavailable") end
    return succeed(capabilities)
end
function M.measure_executable(value: unknown): Reply return fail("UNSUPPORTED", "Docker measures executables inside the selected image") end
function M.close_stdin(value: unknown): Reply return fail("UNSUPPORTED", "Docker stdin closure requires the Docker terminal owner") end
function M.reconcile_internal(value: unknown): Reply
    if actor() ~= "bee.placement.sweeper" then return fail("FORBIDDEN", "only the placement sweeper may dispatch Docker reconciliation") end
    local request, invalid = object(value, "reconcile_internal")
    if not request then return invalid :: Reply end
    local attempt, row, denied = load(request.attempt_id, false)
    if not attempt then return denied :: Reply end
    return M.reconcile_attempt(attempt, row :: Row)
end
return M
