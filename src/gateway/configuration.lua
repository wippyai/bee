-- MIT. The host-approved MCP configuration a harness child receives in its
-- private home: the gateway endpoint the host selected, the action's own
-- tool URL, and a bearer header that names the environment destination the
-- runner fills at materialization. The rendered file never carries the
-- token; placement verifies a launch's configuration against this render
-- before recording intent, so no caller-authored MCP configuration passes.
local hash = require("hash")
local json = require("json")
local registry = require("registry")
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}
M.REVISION = "bee.mcp-config@1"
-- Claude Code reads user-scope MCP servers from this file in its HOME.
M.PATH = ".claude.json"
M.DESTINATION = "BEE_GATEWAY_TOKEN"
M.SERVER = "bee"
M.ENDPOINT = "bee:gateway_endpoint"
type Object = {[string]: unknown}
type Projection = {revision: string, path: string, content: string, digest: string, provider_ref: string}
-- The host selects the one loopback endpoint the listener serves; open
-- refuses any other address and the readiness policy is pinned to it.
function M.endpoint(): (string?, string?)
    local entry, err = registry.get(M.ENDPOINT)
    if err or not entry then return nil, "gateway endpoint is not configured by the host" end
    local data = entry.data
    if type(data) ~= "table" then return nil, "gateway endpoint has no data" end
    local address = (data :: Object).address
    if type(address) ~= "string" or not (address :: string):find("^127%.0%.0%.1:%d+$") then return nil, "gateway endpoint must be a loopback host and port" end
    return address :: string, nil
end
function M.url(address: string, action_id: string): string
    return "http://" .. address .. "/mcp/" .. action_id
end
function M.render(address: string, action_id: string): (string?, string?)
    local document = {mcpServers = {[M.SERVER] = {type = "http", url = M.url(address, action_id), headers = {Authorization = "Bearer ${" .. M.DESTINATION .. "}"}}}}
    local encoded, encode_error = canonical.encode(document)
    if not encoded then return nil, encode_error end
    return encoded .. "\n", nil
end
function M.projection(address: string, action_id: string): (Projection?, string?)
    if not bounds.id(action_id) or action_id:find("[/?#%s]") then return nil, "action_id is not a path segment" end
    local content, render_error = M.render(address, action_id)
    if not content then return nil, render_error end
    local digest, hash_error = hash.sha256(content)
    if hash_error or not digest then return nil, "digest configuration" end
    return {revision = M.REVISION, path = M.PATH, content = content, digest = digest, provider_ref = M.ENDPOINT}, nil
end
-- The Codex form: a section of the provider configuration file naming the
-- same URL and the environment variable Codex reads the bearer token from.
function M.codex_section(address: string, action_id: string): string
    local escaped = M.url(address, action_id):gsub("\\", "\\\\"):gsub('"', '\\"')
    return table.concat({"[mcp_servers." .. M.SERVER .. "]", 'url = "' .. escaped .. '"', 'bearer_token_env_var = "' .. M.DESTINATION .. '"', ""}, "\n")
end
-- The name a Claude Code tool list gives a gateway tool.
function M.claude_tool(tool: string): string
    return "mcp__" .. M.SERVER .. "__" .. tool
end
-- Hook adapters. Both render from the admitted event names, the endpoint
-- and the action; neither carries bytes, both reference the hook credential
-- through its environment destination.
M.HOOK_DESTINATION = "BEE_GATEWAY_HOOK_TOKEN"
M.HOOK_SERVER = "bee_hooks"
M.HOOK_TIMEOUT_SEC = 2
M.CLAUDE_HOOKS_PATH = ".claude/settings.json"
M.CLAUDE_HOOKS_REVISION = "bee.claude-hooks@1"
M.CODEX_HOOKS_PATH = ".codex/hooks.json"
M.CODEX_HOOKS_REVISION = "bee.codex-hooks@1"
M.CODEX_PROFILE = "bee"
M.CODEX_TRUST_PATH = ".codex/bee.config.toml"
-- The Codex event labels of the hook catalog, as its hook keys name them.
M.CODEX_LABELS = {SessionStart = "session_start", UserPromptSubmit = "user_prompt_submit", PreToolUse = "pre_tool_use", PostToolUse = "post_tool_use", Stop = "stop", SessionEnd = "session_end",
    PostToolUseFailure = "", StopFailure = ""}
-- The per-event input templates a Codex mcp_tool handler resolves from the
-- event JSON; a placeholder for a field the event lacks fails the handler,
-- so each template names only what its event carries.
M.CODEX_TEMPLATES = {
    SessionStart = {event = "${hook_event_name}", session_id = "${session_id}", source = "${source}"},
    UserPromptSubmit = {event = "${hook_event_name}", session_id = "${session_id}", turn_id = "${turn_id}", prompt = "${prompt}"},
    PreToolUse = {event = "${hook_event_name}", session_id = "${session_id}", turn_id = "${turn_id}", tool_name = "${tool_name}", tool_use_id = "${tool_use_id}", tool_input = "${tool_input}"},
    PostToolUse = {event = "${hook_event_name}", session_id = "${session_id}", turn_id = "${turn_id}", tool_name = "${tool_name}", tool_use_id = "${tool_use_id}", tool_response = "${tool_response}"},
    Stop = {event = "${hook_event_name}", session_id = "${session_id}", turn_id = "${turn_id}", last_assistant_message = "${last_assistant_message}"},
}
function M.hook_url(address: string, action_id: string): string
    return "http://" .. address .. "/hook/" .. action_id
end
-- Claude Code: a generated hook configuration adapter and nothing else in
-- the user settings file. Each admitted event posts to the action's hook
-- URL with the credential from the environment; the URL and the variable
-- are allowlisted, the timeout bounds every hook.
function M.claude_hooks(address: string, action_id: string, events: {string}): (Projection?, string?)
    if not bounds.id(action_id) or action_id:find("[/?#%s]") then return nil, "action_id is not a path segment" end
    local url = M.hook_url(address, action_id)
    local handler = {type = "http", url = url, headers = {Authorization = "Bearer ${" .. M.HOOK_DESTINATION .. "}"}, allowedEnvVars = {M.HOOK_DESTINATION}, timeout = M.HOOK_TIMEOUT_SEC}
    local hooks: Object = {}
    for _, event in ipairs(events) do hooks[event] = {{matcher = "", hooks = {handler}}} end
    local content, encode_error = canonical.encode({hooks = hooks, allowedHttpHookUrls = {url}, httpHookAllowedEnvVars = {M.HOOK_DESTINATION}})
    if not content then return nil, encode_error end
    content = content .. "\n"
    local digest, hash_error = hash.sha256(content)
    if hash_error or not digest then return nil, "digest hook configuration" end
    return {revision = M.CLAUDE_HOOKS_REVISION, path = M.CLAUDE_HOOKS_PATH, content = content, digest = digest, provider_ref = M.ENDPOINT}, nil
end
type CodexHooks = {section: string, hooks: Projection, trust: {[string]: string}, profile: string}
-- Codex: the hook server section for the provider file (omitted from every
-- model surface), the hooks.json with one mcp_tool handler per admitted
-- event, and the trust hash of each hook as the pinned executable computes
-- it: sha256 over the canonical JSON of the normalized identity {event
-- label, hooks: [handler with its timeout]}, matcher omitted. The runner
-- writes the trust state under the private home's hooks.json path into the
-- profile layer the launch line selects. Events Codex cannot deliver by
-- mcp_tool (SessionEnd) or does not name are left out.
function M.codex_hooks(address: string, action_id: string, events: {string}): (CodexHooks?, string?)
    if not bounds.id(action_id) or action_id:find("[/?#%s]") then return nil, "action_id is not a path segment" end
    local url = M.hook_url(address, action_id) .. "/mcp"
    local escaped = url:gsub("\\", "\\\\"):gsub('"', '\\"')
    local section = table.concat({"[mcp_servers." .. M.HOOK_SERVER .. "]", 'url = "' .. escaped .. '"', 'bearer_token_env_var = "' .. M.HOOK_DESTINATION .. '"', 'omit_tools_from = ["direct", "deferred", "code_mode"]', ""}, "\n")
    local hooks: Object = {}
    local trust: {[string]: string} = {}
    for _, event in ipairs(events) do
        local template = M.CODEX_TEMPLATES[event]
        local label = M.CODEX_LABELS[event]
        if template and label and label ~= "" then
            local handler = {type = "mcp_tool", server = M.HOOK_SERVER, tool = "hook", input = template, timeout = M.HOOK_TIMEOUT_SEC}
            hooks[event] = {{hooks = {handler}}}
            local identity, identity_error = canonical.encode({event_name = label, hooks = {handler}})
            if not identity then return nil, identity_error end
            local sum, hash_error = hash.sha256(identity)
            if hash_error or not sum then return nil, "digest hook identity" end
            trust[label] = "sha256:" .. sum
        end
    end
    local content, encode_error = canonical.encode({hooks = hooks})
    if not content then return nil, encode_error end
    content = content .. "\n"
    local digest, digest_error = hash.sha256(content)
    if digest_error or not digest then return nil, "digest hooks file" end
    return {section = section, hooks = {revision = M.CODEX_HOOKS_REVISION, path = M.CODEX_HOOKS_PATH, content = content, digest = digest, provider_ref = M.ENDPOINT}, trust = trust, profile = M.CODEX_PROFILE}, nil
end
-- The trust state file for one private home: keys name the hooks.json
-- path inside that home, values the hashes computed above.
function M.codex_trust(codex_home: string, trust: {[string]: string}): string
    local labels: {string} = {}
    for label in pairs(trust) do labels[#labels + 1] = label end
    table.sort(labels)
    local lines: {string} = {}
    for _, label in ipairs(labels) do
        lines[#lines + 1] = '[hooks.state."' .. codex_home .. "/hooks.json:" .. label .. ':0:0"]'
        lines[#lines + 1] = 'trusted_hash = "' .. trust[label] .. '"'
    end
    return table.concat(lines, "\n") .. "\n"
end
-- decode reads a rendered configuration back for the fixture child and
-- for tests; the runtime never interprets it.
function M.decode(content: string): (Object?, string?)
    local value: unknown, err = json.decode(content)
    if err or type(value) ~= "table" then return nil, "configuration is not a JSON object" end
    return value :: Object, nil
end
return M
