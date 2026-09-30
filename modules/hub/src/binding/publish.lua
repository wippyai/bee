-- MIT. Person-approved Hub publication effect: snapshot the admitted
-- source, measure the exact content bytes, upload from the immutable
-- snapshot and record a digest-bound receipt. Called only inside the named
-- publish worker after facade authorization. The uploader command carries
-- no credential; only digests and a bounded failure line enter receipts.
-- The worker needs a POSIX sh with GNU find, sort and sha256sum on its
-- dedicated executor; any other host leaves publication unconfigured.
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
type Measured = {component: string, version: string, digest: string, visibility: string,
    organization: string, source: string}
type Receipt = {actor_id: string, digest: string, component: string, version: string, visibility: string,
    organization: string, source: string, content_digest: string, hub_digest: string,
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

local function shell(directory: string, script: string, executor_ref: string): (Run?, string?)
    return run({"sh", "-c", script, "bee-publish-snapshot", directory}, executor_ref)
end

-- tree_digest: the content measurement of a directory tree: every regular
-- file's sha256, ordered by path, hashed once. The stream is a pure
-- function of file paths and bytes, so equal trees measure equal digests.
-- Anything that is not a regular file or directory is refused: links and
-- special files never enter an approved snapshot.
local function tree_digest(directory: string, executor_ref: string): (string?, string?)
    local odd, odd_error = shell(directory, 'find . \\( -not -type f -not -type d \\) -print -quit', executor_ref)
    if not odd then return nil, odd_error end
    if odd.code ~= 0 then return nil, "content walk failed: " .. first_line(odd.err) end
    if odd.out ~= "" then return nil, "publication source holds links or special files; stage plain files" end
    local measured, measure_error = shell(directory,
        'find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2 | sha256sum', executor_ref)
    if not measured then return nil, measure_error end
    if measured.code ~= 0 then return nil, "content measurement failed: " .. first_line(measured.err) end
    local digest = measured.out:match("^([0-9a-f][0-9a-f]+)")
    if not digest or #digest ~= 64 then return nil, "content measurement is malformed" end
    return digest, nil
end

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
    local content = hex(value.content_digest)
    local hub = value.hub_digest
    if type(hub) ~= "string" then return nil end
    if (hub :: string) ~= "" and not (hub :: string):match("^sha256:[0-9a-f]+$") then return nil end
    local state = bounds.member(value.state, {"published", "failed"})
    local message = bounds.text(value.message, 4096)
    local action = bounds.member(value.action, {"publish"})
    if not actor or not digest or not component or not version or not visibility or not organization
        or not source or not content or not state or not message or not action then
        return nil
    end
    return {actor_id = actor, digest = digest, component = component, version = version, visibility = visibility,
        organization = organization, source = source, content_digest = content, hub_digest = hub :: string,
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

local function save_staging(digest: string, snapshot: string, measured: Object): (boolean, string?)
    local snapshot_state, problem = registry.snapshot()
    if not snapshot_state then return false, tostring(problem) end
    local changes, change_error = snapshot_state:changes()
    if not changes then return false, tostring(change_error) end
    local entry = {id = staging_id(digest), kind = "registry.entry",
        data = {snapshot = snapshot, measured = measured}}
    local staged, stage_error
    if snapshot_state:get(entry.id) then staged, stage_error = changes:update(entry)
    else staged, stage_error = changes:create(entry) end
    if not staged then return false, tostring(stage_error) end
    local _, apply_error = changes:apply()
    if apply_error then return false, tostring(apply_error) end
    return true, nil
end

local function load_staging(digest: string): ({snapshot: string, measured: Measured}?, string?)
    local snapshot_state, problem = registry.snapshot()
    if not snapshot_state then return nil, tostring(problem) end
    local entry = snapshot_state:get(staging_id(digest))
    if not entry then return nil, "staged publication is unavailable; file a new publish request" end
    local data = bounds.object(entry.data)
    if not data then return nil, "staged publication is unavailable; file a new publish request" end
    local snapshot = bounds.text(data.snapshot, 8192)
    if not snapshot then return nil, "staged publication is unavailable; file a new publish request" end
    if snapshot:sub(1, 1) ~= "/" then return nil, "staged publication is unavailable; file a new publish request" end
    local measured = measured_record(data.measured)
    if not measured then return nil, "staged publication is unavailable; file a new publish request" end
    local staged: {snapshot: string, measured: Measured} = {snapshot = snapshot, measured = measured}
    return staged, nil
end

-- snapshot_tree: copy the admitted source into the worker-owned staging
-- root under its content digest. Equal bytes reuse one snapshot, so a
-- repeated plan never duplicates the tree. The snapshot is immutable to
-- agents, and the upload packs exactly these bytes.
local function snapshot_tree(source: string, staging_root: string, executor_ref: string): (string?, string?, string?)
    local prepared, prepare_error = run({"mkdir", "-p", staging_root}, executor_ref)
    if not prepared then return nil, nil, prepare_error end
    if prepared.code ~= 0 then return nil, nil, "snapshot staging failed: " .. first_line(prepared.err) end
    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(1, 1073741824))
    local tmp = staging_root .. "/publish-" .. stamp
    local copied, copy_error = run({"cp", "-a", source, tmp}, executor_ref)
    if not copied then return nil, nil, copy_error end
    if copied.code ~= 0 then return nil, nil, "source snapshot failed: " .. first_line(copied.err) end
    local digest, digest_error = tree_digest(tmp, executor_ref)
    if not digest then
        run({"rm", "-rf", tmp}, executor_ref)
        return nil, nil, digest_error
    end
    local dest = staging_root .. "/" .. digest
    local present, present_error = run({"test", "-e", dest}, executor_ref)
    if not present then
        run({"rm", "-rf", tmp}, executor_ref)
        return nil, nil, present_error
    end
    if present.code == 0 then
        run({"rm", "-rf", tmp}, executor_ref)
        return dest, digest, nil
    end
    local moved, move_error = run({"mv", tmp, dest}, executor_ref)
    if not moved then
        run({"rm", "-rf", tmp}, executor_ref)
        return nil, nil, move_error
    end
    if moved.code ~= 0 then
        run({"rm", "-rf", tmp}, executor_ref)
        return nil, nil, "snapshot staging failed: " .. first_line(moved.err)
    end
    return dest, digest, nil
end

-- plan: snapshot the admitted source, measure the exact bytes and record
-- where they wait for the person's decision. A source that does not pack
-- is refused before any approval. The returned plan digest binds module,
-- version, content digest, visibility, organization and source.
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
    local snapshot, digest, snapshot_error = snapshot_tree(admitted, config.staging_root, executor_ref)
    if not snapshot or not digest then return nil, snapshot_error end
    local preflight, preflight_error = run(publishing.plan_command(
        {component = decoded.component, version = decoded.version,
            visibility = decoded.visibility, source = snapshot}, config.cli), executor_ref)
    if not preflight then return nil, preflight_error end
    if preflight.code ~= 0 then return nil, "module pack failed: " .. first_line(preflight.err) end
    local measured: Object = {component = decoded.component, version = decoded.version, digest = digest,
        visibility = decoded.visibility, organization = config.organization, source = admitted}
    local plan_digest = publishing.plan_digest(measured)
    if not plan_digest then return nil, "publication measurement cannot be encoded" end
    local saved, save_error = save_staging(plan_digest, snapshot, measured)
    if not saved then return nil, save_error end
    measured.plan_digest = plan_digest
    return measured, nil
end

-- apply: upload from the snapshot the approved plan digest names and record
-- the receipt. The snapshot is re-measured first: changed bytes refuse the
-- upload. A digest that already has a receipt replays it.
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
    local measured = staged.measured
    if publishing.plan_digest({component = measured.component, version = measured.version, digest = measured.digest,
        visibility = measured.visibility, organization = measured.organization, source = measured.source}) ~= plan_digest then
        return transaction.failure("INTERNAL", "staged publication differs from the confirmed plan")
    end
    local config, config_error = host_resources.publish_config()
    if not config then return transaction.failure("UNAVAILABLE", tostring(config_error)) end
    local executor_ref, executor_error = host_resources.publish_executor()
    if not executor_ref then return transaction.failure("UNAVAILABLE", tostring(executor_error)) end
    local content, content_error = tree_digest(staged.snapshot, executor_ref)
    if not content then
        return transaction.failure("NOT_FOUND", tostring(content_error) .. "; file a new publish request")
    end
    if content ~= measured.digest then
        return transaction.failure("FAILED", "staged snapshot changed after approval; file a new publish request")
    end
    type UploadRequest = {action: string, component: string, version: string, visibility: string,
        digest: string, organization: string, source: string}
    local upload_request: UploadRequest = {action = "publish", component = measured.component,
        version = measured.version, visibility = measured.visibility, digest = content,
        organization = measured.organization, source = measured.source}
    local verified = {request = upload_request, digest = plan_digest}
    local uploaded, upload_error = run(publishing.publish_command(verified, config.cli, staged.snapshot), executor_ref)
    if not uploaded then return transaction.failure("UNCERTAIN", tostring(upload_error)) end
    local hub_digest = publishing.parse_digest(uploaded.out)
    if uploaded.code == 0 and type(hub_digest) == "string" then
        return save_receipt({actor_id = actor:id(), digest = plan_digest, component = measured.component,
            version = measured.version, visibility = measured.visibility,
            organization = measured.organization, source = measured.source,
            content_digest = content, hub_digest = hub_digest, state = "published",
            message = "Publication completed", action = "publish"})
    end
    -- The upload did not report a digest, or the version already exists:
    -- the worker serializes publications, so a version present on the Hub
    -- after this attempt holds this snapshot's bytes. The receipt records
    -- the Hub's own digest beside the approved content digest.
    local inspected, inspect_error = inspect.read({component = measured.component, version = measured.version})
    if inspected then
        local receipt = save_receipt({actor_id = actor:id(), digest = plan_digest, component = measured.component,
            version = measured.version, visibility = measured.visibility,
            organization = measured.organization, source = measured.source,
            content_digest = content, hub_digest = "sha256:" .. inspected.digest, state = "published",
            message = "Version already on Hub; receipt restored", action = "publish"})
        receipt.replayed = true
        return receipt
    end
    if uploaded.code == 0 then
        return transaction.failure("UNCERTAIN", "upload finished without a Hub digest; Hub read: " ..
            first_line(tostring(inspect_error)))
    end
    local message = "uploader refused publication (exit " .. tostring(uploaded.code) .. "): " .. first_line(uploaded.err)
    if inspect_error then message = message .. "; Hub read: " .. first_line(tostring(inspect_error)) end
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
