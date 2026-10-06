-- SPDX-License-Identifier: MIT
-- The gateway tools through which an agent attempt exercises a held
-- elevation. process_run runs the approved command, followed by the
-- agent's own arguments, in the approved folder of the bound workspace
-- through the host process executor, with no environment beyond the host
-- PATH; http_request sends one request under the approved origin, methods
-- and path prefix. The elevation is checked before either is called.
local exec = require("exec")
local bounds = require("bounds")
local quote = require("quote")
local probe_capture = require("probe_capture")
local resources = require("resources")
local files = require("capability_files")
local capability_http = require("capability_http")
local capability = require("capability")
local subject_call = require("subject_call")
local M = {}
M.EXECUTOR = "bee.gateway.env:process_executor"
M.FOLDER_READ_REF = "bee.gateway.env:workspace_folder_read_ref"
M.FOLDER_POLICY_REF = "bee.gateway.env:workspace_folder_policy_ref"
M.MAX_ARGUMENTS = 64
M.MAX_ARGUMENT_BYTES = 4096
M.MAX_OUTPUT_BYTES = 1048576
M.DEFAULT_TIMEOUT_MS = 120000
M.MAX_TIMEOUT_MS = 600000
type Object = {[string]: unknown}
type Binding = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, workspace_id: string?}
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
local fail = subject_call.fail

-- The approved folder: the bound workspace's folder as the node catalog
-- records it, resolved on this host, and the verified subroot under it.
local function folder(binding: Binding, subpath: unknown): (string?, Reply?)
    local workspace_id = binding.workspace_id
    if not workspace_id then return nil, fail("DENIED", "this binding names no workspace to run in") end
    local read_id, read_error = subject_call.linked(M.FOLDER_READ_REF, "workspace folder read")
    if not read_id then return nil, read_error end
    local policy_id, policy_error = subject_call.linked(M.FOLDER_POLICY_REF, "workspace folder read policy")
    if not policy_id then return nil, policy_error end
    local read = subject_call.call(binding, {policy_id}, read_id, {workspace_id = workspace_id})
    if not read.ok then return nil, read end
    local value = bounds.object(read.value)
    local row = value and bounds.object(value.workspace) or nil
    local root_ref = row and bounds.id(row.root_ref) or nil
    local workspace_subpath = row and row.subpath or nil
    if not root_ref or type(workspace_subpath) ~= "string" then
        return nil, fail("UNAVAILABLE", "the workspace catalog returned no folder")
    end
    local directory, directory_error = resources.directory(root_ref)
    if not directory then return nil, fail("UNAVAILABLE", tostring(directory_error)) end
    local path = directory
    local function under(child: string)
        path = path:sub(-1) == "/" and path .. child or path .. "/" .. child
    end
    if workspace_subpath ~= "" then under(workspace_subpath) end
    if subpath ~= "." then
        local verified, subpath_error = files.verify_subpath(subpath)
        if not verified then return nil, fail("DENIED", tostring(subpath_error)) end
        under(verified)
    end
    return path, nil
end

-- process: {approval_id, arguments?, timeout_ms?}. The reply carries the
-- exit code and the combined output.
function M.process(binding: Binding, request: capability.Request, raw: unknown): Reply
    local object = bounds.object(raw)
    if not object or bounds.fields(object, {"binding_id", "approval_id", "arguments", "timeout_ms"}) then
        return fail("INVALID", "process run request is malformed")
    end
    local rows = bounds.dense_list(object.arguments == nil and {} or object.arguments, M.MAX_ARGUMENTS, "arguments")
    if not rows then return fail("INVALID", "arguments must be a list of at most " .. tostring(M.MAX_ARGUMENTS) .. " strings") end
    local arguments: {string} = {}
    for _, item in ipairs(rows) do
        if type(item) ~= "string" or #item > M.MAX_ARGUMENT_BYTES or item:find("%z") then
            return fail("INVALID", "each argument must be a string of at most " .. tostring(M.MAX_ARGUMENT_BYTES) .. " bytes")
        end
        arguments[#arguments + 1] = item
    end
    local timeout = M.DEFAULT_TIMEOUT_MS
    if object.timeout_ms ~= nil then
        local declared = bounds.integer(object.timeout_ms)
        if not declared or declared < 1 or declared > M.MAX_TIMEOUT_MS then
            return fail("INVALID", "timeout_ms must be between 1 and " .. tostring(M.MAX_TIMEOUT_MS))
        end
        timeout = declared
    end
    local grant = request.operations[1]
    local scope = grant and bounds.object(grant.scope) or nil
    if not grant or grant.capability ~= "process.exec" or not scope then
        return fail("DENIED", "the held capability does not run a process")
    end
    local directory, directory_failure = folder(binding, scope.subpath)
    if not directory then return directory_failure or fail("UNAVAILABLE", "approved folder is unavailable") end
    local line = grant.resource
    if #arguments > 0 then line = line .. " " .. quote.line(arguments) end
    local executor, executor_error = exec.get(M.EXECUTOR)
    if not executor then return fail("UNAVAILABLE", tostring(executor_error)) end
    local process, process_error = executor:exec(line, {work_dir = directory})
    if not process then
        executor:release()
        return fail("FAILED", tostring(process_error))
    end
    local stdout, stdout_error = process:stdout_stream()
    local stderr, stderr_error = process:stderr_stream()
    if not stdout or not stderr then
        process:close(true)
        executor:release()
        return fail("FAILED", tostring(stdout_error or stderr_error))
    end
    local started, start_error = process:start()
    if not started then
        process:close(true)
        executor:release()
        return fail("FAILED", tostring(start_error))
    end
    local captured: probe_capture.Process = {
        wait = function(_self) return process:wait() end,
        close = function(_self, force) process:close(force) end,
    }
    local out: probe_capture.Stream = {
        read = function(_self: probe_capture.Stream, size: integer): (unknown, unknown) local value, err = stdout:read(size); return value, err end,
        close = function(_self: probe_capture.Stream): unknown stdout:close(); return nil end,
    }
    local err: probe_capture.Stream = {
        read = function(_self: probe_capture.Stream, size: integer): (unknown, unknown) local value, read_error = stderr:read(size); return value, read_error end,
        close = function(_self: probe_capture.Stream): unknown stderr:close(); return nil end,
    }
    local output, code, capture_error = probe_capture.capture(captured, out, err,
        function() executor:release() end, timeout, M.MAX_OUTPUT_BYTES)
    if output == nil then return fail("FAILED", tostring(capture_error)) end
    return {ok = true, value = {exit_code = code, output = output}}
end

-- http: {approval_id, method, url, headers?, body?, timeout?}.
function M.http(request: capability.Request, raw: unknown): Reply
    local object = bounds.object(raw)
    if not object then return fail("INVALID", "HTTP request is malformed") end
    local outgoing: Object = {}
    for key, value in pairs(object) do
        if key ~= "binding_id" and key ~= "approval_id" then outgoing[key] = value end
    end
    return capability_http.perform(outgoing, function(): ({unknown}?, Reply?)
        return request.operations, nil
    end)
end

return M
