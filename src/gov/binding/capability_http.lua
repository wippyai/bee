-- MIT. One HTTP request under approved http.api grants: an application's
-- installed grants through the Gov gateway, or an agent attempt's held
-- elevation through the agent gateway. The request is checked against the
-- exact approved origin, method and path prefix before it is sent, and the
-- response is returned only when it arrived from under an approved origin
-- and path prefix.
local http_client = require("http_client")
local bounds = require("bounds")
local gateway = require("capability_gateway")

local M = {}
M.MAX_BODY = 1048576
M.MAX_RESPONSE = 4194304
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
-- The approved grants, read only after the request itself is well formed.
type Grants = () -> ({unknown}?, Reply?)

local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end

-- request: {method, url, headers?, body?, timeout?}.
function M.perform(request_raw: unknown, grants: Grants): Reply
    local request = bounds.object(request_raw)
    if not request or bounds.fields(request, {"method", "url", "headers", "body", "timeout"}) then
        return fail("INVALID", "HTTP request is malformed")
    end
    local headers: {[string]: string} = {}
    if request.headers ~= nil then
        local supplied = bounds.object(request.headers)
        if not supplied then return fail("INVALID", "HTTP headers are malformed") end
        for key, value in pairs(supplied) do
            if type(value) ~= "string" or #key > 128 or #value > 8192
                or key:find("[%c:]") or value:find("[\r\n]") then
                return fail("INVALID", "HTTP headers are malformed")
            end
            headers[key] = value
        end
    end
    local body: string? = nil
    if request.body ~= nil then
        if type(request.body) ~= "string" or #request.body > M.MAX_BODY then
            return fail("INVALID", "HTTP body is malformed")
        end
        body = request.body
    end
    local timeout = request.timeout
    if timeout == nil then timeout = 30 end
    if type(timeout) ~= "number" or timeout <= 0 or timeout > 60 then
        return fail("INVALID", "HTTP timeout is malformed")
    end
    local capabilities, refusal = grants()
    if not capabilities then return refusal or fail("DENIED", "no grant authorizes this caller") end
    local allowed, denied = gateway.http_granted(capabilities, request.method, request.url)
    if not allowed then return fail("DENIED", tostring(denied)) end
    local method, url = request.method, request.url
    if type(method) ~= "string" or type(url) ~= "string" then return fail("DENIED", "HTTP request target is malformed") end
    local response, request_error = http_client.request(method:upper(), url,
        {headers = headers, body = body, timeout = timeout, max_response_body = M.MAX_RESPONSE})
    if not response then return fail("FAILED", tostring(request_error)) end
    local arrived = response.url or url
    local located, location_error = gateway.located_in(capabilities, arrived)
    if not located then return fail("DENIED", tostring(location_error)) end
    return {ok = true, error = nil, value = {status_code = response.status_code, headers = response.headers,
        body = response.body}}
end

return M
