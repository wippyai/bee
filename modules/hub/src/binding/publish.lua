-- MIT. Person-approved Hub publication effect: pack the admitted source
-- once, measure the exact bytes, upload the staged file byte for byte and
-- record a digest-bound receipt. Called only inside the named publish
-- worker after facade authorization. The uploader command carries no
-- credential; only digests and a bounded failure line enter receipts.
local registry = require("registry")
local security = require("security")
local exec = require("exec")
local channel = require("channel")
local bounds = require("bounds")
local publishing = require("publishing")
local transaction = require("transaction")
local inspect = require("inspect")
local host_resources = require("host_resources")
local paths = require("paths")
local quote = require("quote")
local M = {}
type Result = transaction.Result
type Object = {[string]: unknown}
type Receipt = {actor_id: string, digest: string, component: string, version: string, visibility: string,
    organization: string, source: string, pack_digest: string, hub_digest: string,
    state: string, message: string, action: string}
M.MAX_STDOUT_BYTES = 256 * 1024
M.MAX_STDERR_BYTES = 64 * 1024
M.MAX_MESSAGE_BYTES = 300

local function receipt_id(digest: string): string return "bee.hub.publish_operations:" .. digest end
local function staging_id(digest: string): string return "bee.hub.publish_staging:" .. digest end

local function hex(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function first_line(output: string): string
    local line = output:match("^([^\n]*)\n?") or ""
    if #line > M.MAX_MESSAGE_BYTES then line = line:sub(1, M.MAX_MESSAGE_BYTES) end
    return line
end

type Run = {code: integer, out: string, err: string}

local function run(argv: {string}, executor_ref: string): (Run?, string?)
    local executor, executor_error = exec.get(executor_ref)
    if not executor then return nil, "publisher executor unavailable: " .. tostring(executor_error) end
    local proc, exec_error = executor:exec(quote.line(argv))
    if not proc then
        executor:release()
        return nil, "publisher executor refused the command"
    end
    local stdout = proc:stdout_stream()
    local stderr = proc:stderr_stream()
    local started, start_error = proc:start()
    if not started then
        executor:release()
        return nil, "publisher command did not start: " .. tostring(start_error)
    end
    local errors = channel.new(1)
    local err_chunks: {string} = {}
    local err_bytes = 0
    coroutine.spawn(function()
        while stderr do
            local chunk = stderr:read(4096)
            if not chunk or chunk == "" then break end
            if err_bytes < M.MAX_STDERR_BYTES then
                err_chunks[#err_chunks + 1] = tostring(chunk)
                err_bytes = err_bytes + #tostring(chunk)
            end
        end
        errors:send(true)
    end)
    local out_chunks: {string} = {}
    local out_bytes = 0
    while true do
        local chunk = stdout:read(4096)
        if not chunk or chunk == "" then break end
        out_bytes = out_bytes + #tostring(chunk)
        if out_bytes <= M.MAX_STDOUT_BYTES then out_chunks[#out_chunks + 1] = tostring(chunk) end
    end
    errors:receive()
    stdout:close()
    if stderr then stderr:close() end
    local code, wait_error = proc:wait()
    executor:release()
    if wait_error then return nil, "publisher command did not finish: " .. tostring(wait_error) end
    if out_bytes > M.MAX_STDOUT_BYTES then return nil, "publisher output exceeds its bound" end
    local exit_code = (type(code) == "number") and math.floor(code) or -1
    return {code = exit_code, out = table.concat(out_chunks), err = table.concat(err_chunks)}, nil
end

local function file_digest(path: string, executor_ref: string): (string?, string?)
    local result, run_error = run({"sha256sum", "--", path}, executor_ref)
    if not result then return nil, run_error end
    if result.code ~= 0 then return nil, "staged pack cannot be measured: " .. first_line(result.err) end
    local digest = result.out:match("^([0-9a-f][0-9a-f]+)")
    if not digest or #digest ~= 64 then return nil, "staged pack measurement is malformed" end
    return digest, nil
end

local function decode_receipt(raw: unknown): Receipt?
    local value = bounds.object(raw)
    if not value then return nil end
    local actor = bounds.id(value.actor_id)
    local digest = hex(value.digest)
    local component = bounds.line(value.component, 160)
    local version = bounds.text(value.version, 128)
    local visibility = bounds.member(value.visibility, {"public", "private"})
    local organization = bounds.line(value.organization, 128)
    local source = bounds.text(value.source, 8192)
    local pack = hex(value.pack_digest)
    local hub = value.hub_digest == "" and "" or value.hub_digest
    if type(hub) ~= "string" then return nil end
    if (hub :: string) ~= "" and not (hub :: string):match("^sha256:[0-9a-f]+$") then return nil end
    local state = bounds.member(value.state, {"published", "failed"})
    local message = bounds.text(value.message, 4096)
    local action = bounds.member(value.action, {"publish"})
    if not actor or not digest or not component or not version or not visibility or not organization
        or not source or not pack or not state or not message or not action then
        return nil
    end
    return {actor_id = actor, digest = digest, component = component, version = version, visibility = visibility,
        organization = organization, source = source, pack_digest = pack, hub_digest = hub :: string,
        state = state, message = message, action = action}
end

local function save_receipt(receipt: Receipt): Result
    local snapshot, problem = registry.snapshot()
    if not snapshot then return transaction.failure("UNCERTAIN", tostring(problem)) end
    local changes, change_error = snapshot:changes()
    if not changes then return transaction.failure("UNCERTAIN", tostring(change_error)) end
    local entry = {id = receipt_id(receipt.digest), kind = "registry.entry", data = receipt}
    local staged, stage_error
    if snapshot:get(entry.id) then staged, stage_error = changes:update(entry)
    else staged, stage_error = changes:create(entry) end
    if not staged then return transaction.failure("UNCERTAIN", tostring(stage_error)) end
    local version, apply_error = changes:apply()
    if not version then return transaction.failure("UNCERTAIN", tostring(apply_error)) end
    return transaction.success(receipt, false)
end

local function save_staging(digest: string, pack_path: string, measured: Object): (boolean, string?)
    local snapshot, problem = registry.snapshot()
    if not snapshot then return false, tostring(problem) end
    local changes, change_error = snapshot:changes()
    if not changes then return false, tostring(change_error) end
    local entry = {id = staging_id(digest), kind = "registry.entry",
        data = {pack_path = pack_path, measured = measured}}
    local staged, stage_error
    if snapshot:get(entry.id) then staged, stage_error = changes:update(entry)
    else staged, stage_error = changes:create(entry) end
    if not staged then return false, tostring(stage_error) end
    local _, apply_error = changes:apply()
    if apply_error then return false, tostring(apply_error) end
    return true, nil
end

type Measured = {component: string, version: string, digest: string, visibility: string,
    organization: string, source: string}

local function measured_record(raw: unknown): Measured?
    local value = bounds.object(raw)
    if not value then return nil end
    local component = bounds.line(value.component, 160)
    local version = bounds.text(value.version, 128)
    local digest = hex(value.digest)
    local visibility = bounds.member(value.visibility, {"public", "private"})
    local organization = bounds.line(value.organization, 128)
    local source = bounds.text(value.source, 8192)
    if not component or not version or not digest or not visibility or not organization or not source then
        return nil
    end
    return {component = component, version = version, digest = digest,
        visibility = visibility, organization = organization, source = source}
end

local function load_staging(digest: string): ({pack_path: string, measured: Measured}?, string?)
    local snapshot, problem = registry.snapshot()
    if not snapshot then return nil, tostring(problem) end
    local entry = snapshot:get(staging_id(digest))
    if not entry then return nil, "staged publication is unavailable; file a new publish request" end
    local data = bounds.object(entry.data)
    if not data then return nil, "staged publication is unavailable; file a new publish request" end
    local pack_path = bounds.text(data.pack_path, 8192)
    if not pack_path then return nil, "staged publication is unavailable; file a new publish request" end
    if pack_path:sub(1, 1) ~= "/" then return nil, "staged publication is unavailable; file a new publish request" end
    local measured = measured_record(data.measured)
    if not measured then return nil, "staged publication is unavailable; file a new publish request" end
    local staged: {pack_path: string, measured: Measured} = {pack_path = pack_path, measured = measured}
    return staged, nil
end

-- plan: pack the admitted source without uploading, measure the staged
-- bytes and record where they wait for the person's decision. The returned
-- plan digest binds module, version, pack digest, visibility, organization
-- and source; the gateway files exactly this for approval.
function M.plan(raw: unknown): (Object?, string?)
    if not security.can("bee.hub.execute", "bee.hub.service:publish_worker") then
        return nil, "Hub publish worker authority required"
    end
    local actor = security.actor()
    if not actor then return nil, "authenticated publisher required" end
    local decoded, decode_error = publishing.decode(raw)
    if not decoded then return nil, decode_error end
    local config, config_error = host_resources.publish_config()
    if not config then return nil, config_error end
    local executor_ref, executor_error = host_resources.publish_executor()
    if not executor_ref then return nil, executor_error end
    local admitted, admit_error = paths.admit(decoded.source, config.source_roots, executor_ref)
    if not admitted then return nil, admit_error or "publication source is not admitted" end
    local staged, stage_error = run(publishing.plan_command(
        {component = decoded.component, version = decoded.version,
            visibility = decoded.visibility, source = admitted}, config.cli), executor_ref)
    if not staged then return nil, stage_error end
    if staged.code ~= 0 then return nil, "module pack failed: " .. first_line(staged.err) end
    local pack_path = publishing.parse_pack_path(staged.out)
    if not pack_path then return nil, "pack report names no staged file" end
    local pack_digest, digest_error = file_digest(pack_path, executor_ref)
    if not pack_digest then return nil, digest_error end
    local measured: Object = {component = decoded.component, version = decoded.version, digest = pack_digest,
        visibility = decoded.visibility, organization = config.organization, source = admitted}
    local plan_digest = publishing.plan_digest(measured)
    if not plan_digest then return nil, "publication measurement cannot be encoded" end
    local saved, save_error = save_staging(plan_digest, pack_path, measured)
    if not saved then return nil, save_error end
    measured.plan_digest = plan_digest
    return measured, nil
end

-- apply: upload the staged bytes the approved plan digest names and record
-- the receipt. A digest that already has a receipt replays it; bytes that
-- already sit on the Hub with the same digest complete without re-upload.
-- The named component must equal the staged one: the facade authorizes the
-- call for that component before the worker starts.
function M.apply(raw: unknown): Result
    if not security.can("bee.hub.execute", "bee.hub.service:publish_worker") then
        return transaction.failure("DENIED", "Hub publish worker authority required")
    end
    local actor = security.actor()
    if not actor then return transaction.failure("DENIED", "authenticated publisher required") end
    local request = bounds.object(raw)
    local plan_digest = request and hex(request.plan_digest) or nil
    local component = request and bounds.line(request.component, 160) or nil
    if not plan_digest or not component then
        return transaction.failure("INVALID", "confirmation requires the component and its plan digest")
    end
    local outcome = M.status(plan_digest)
    if outcome.ok then
        outcome.replayed = true
        return outcome
    end
    if outcome.code ~= "NOT_FOUND" then return outcome end
    local staged, stage_error = load_staging(plan_digest)
    if not staged then return transaction.failure("NOT_FOUND", tostring(stage_error)) end
    if staged.measured.component ~= component then
        return transaction.failure("STALE", "request differs from the confirmed publication; refresh its plan")
    end
    local measured: Measured = staged.measured
    if publishing.plan_digest({component = measured.component, version = measured.version, digest = measured.digest,
        visibility = measured.visibility, organization = measured.organization, source = measured.source}) ~= plan_digest then
        return transaction.failure("INTERNAL", "staged publication differs from the confirmed plan")
    end
    local config, config_error = host_resources.publish_config()
    if not config then return transaction.failure("UNAVAILABLE", tostring(config_error)) end
    local executor_ref, executor_error = host_resources.publish_executor()
    if not executor_ref then return transaction.failure("UNAVAILABLE", tostring(executor_error)) end
    local pack_digest, digest_error = file_digest(staged.pack_path, executor_ref)
    if not pack_digest then
        return transaction.failure("NOT_FOUND", tostring(digest_error) .. "; file a new publish request")
    end
    if pack_digest ~= staged.measured.digest then
        return transaction.failure("FAILED", "staged pack changed after approval; file a new publish request")
    end
    type UploadRequest = {action: string, component: string, version: string, visibility: string,
        digest: string, organization: string, source: string}
    local upload_request: UploadRequest = {action = "publish", component = measured.component,
        version = measured.version, visibility = measured.visibility, digest = pack_digest,
        organization = measured.organization, source = measured.source}
    local verified = {request = upload_request, digest = plan_digest}
    local uploaded, upload_error = run(publishing.publish_command(verified, config.cli, staged.pack_path), executor_ref)
    if not uploaded then return transaction.failure("UNCERTAIN", tostring(upload_error)) end
    local hub_digest = publishing.parse_digest(uploaded.out)
    if uploaded.code == 0 and type(hub_digest) == "string" and hub_digest == "sha256:" .. pack_digest then
        return save_receipt({actor_id = actor:id(), digest = plan_digest, component = measured.component,
            version = measured.version, visibility = measured.visibility,
            organization = measured.organization, source = measured.source,
            pack_digest = pack_digest, hub_digest = hub_digest, state = "published",
            message = "Publication completed", action = "publish"})
    end
    local inspected, inspect_error = inspect.read({component = measured.component, version = measured.version})
    if inspected and inspected.digest == pack_digest then
        local receipt = save_receipt({actor_id = actor:id(), digest = plan_digest, component = measured.component,
            version = measured.version, visibility = measured.visibility,
            organization = measured.organization, source = measured.source,
            pack_digest = pack_digest, hub_digest = "sha256:" .. pack_digest, state = "published",
            message = "Version already published with identical bytes", action = "publish"})
        receipt.replayed = true
        return receipt
    end
    local message = "uploader refused publication (exit " .. tostring(uploaded.code) .. "): " .. first_line(uploaded.err)
    if inspected then message = message .. "; Hub holds another digest for this version" end
    if inspect_error and uploaded.code ~= 0 then message = message .. "; Hub read: " .. first_line(tostring(inspect_error)) end
    return transaction.failure("FAILED", message)
end

-- status: receipt reads run in the backend without worker authority; only
-- the publishing actor reads its own receipts.
function M.status(plan_digest_raw: unknown): Result
    local plan_digest = hex(plan_digest_raw)
    if plan_digest_raw ~= nil and not plan_digest then
        return transaction.failure("INVALID", "invalid plan digest")
    end
    local actor = security.actor()
    if not actor then return transaction.failure("DENIED", "authenticated publisher required") end
    if not plan_digest then return transaction.failure("INVALID", "publication receipt requires a plan digest") end
    local snapshot, problem = registry.snapshot()
    if not snapshot then return transaction.failure("UNAVAILABLE", tostring(problem)) end
    local entry = snapshot:get(receipt_id(plan_digest))
    if not entry then return transaction.failure("NOT_FOUND", "no publication for this plan") end
    local receipt = decode_receipt(entry.data)
    if not receipt or receipt.digest ~= plan_digest then
        return transaction.failure("INTERNAL", "invalid Hub publication receipt")
    end
    if receipt.actor_id ~= actor:id() then return transaction.failure("DENIED", "publication belongs to another actor") end
    return transaction.success(receipt, false)
end

return M
