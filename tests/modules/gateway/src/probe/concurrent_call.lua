-- MIT. Fixture worker for overlapping real MCP HTTP requests.
local http_client = require("http_client")
local json = require("json")
local function handle(address: string, token: string, experiment: string)
    local body = json.encode({jsonrpc = "2.0", id = experiment, method = "tools/call", params = {name = "session",
        arguments = {operation = "select", expected_revision = 2, active_traits = {"research:measure"}, context = {experiment = experiment}}}})
    local response, err = http_client.post("http://" .. address .. "/mcp/configurable", {headers = {
        Authorization = "Bearer " .. token, ["Content-Type"] = "application/json"}, body = body, timeout = "8s"})
    if not response or err then error("concurrent HTTP request failed") end
    local envelope = json.decode(tostring(response.body))
    if type(envelope) ~= "table" then error("concurrent response missing") end
    local content = envelope.result.content[1].text
    if type(content) ~= "string" then error("concurrent response has no JSON content") end
    return json.decode(content)
end
return {handle = handle}
