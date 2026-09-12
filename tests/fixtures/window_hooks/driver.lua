-- MIT. An actual child submits hooks and remains interactive on its PTY.
local M = {}

function M.prepare(_: unknown): {[string]: unknown}
    local script = [[
settings="$HOME/.claude/settings.json"
url=""
if [ -f "$settings" ]; then
    url=$(grep -o 'http://[^"]*' "$settings" | head -n 1)
fi

if [ -z "$BEE_GATEWAY_HOOK_TOKEN" ]; then
    printf 'HOOK_ERR:NO_TOKEN\n'
elif [ -z "$url" ]; then
    printf 'HOOK_ERR:NO_URL\n'
else
    for delivery in 1 2; do
    http_code=$(curl --max-time 5 -s -o /dev/null -w "%{http_code}" -X POST "$url" \
        -H "Authorization: Bearer $BEE_GATEWAY_HOOK_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"hook_event_name":"PreToolUse","session_id":"s1","prompt_id":"p1","tool_use_id":"toolu_1","tool_name":"Bash","tool_input":{"command":"echo test"}}')
    printf 'HOOK_HTTP_CODE:%s\n' "$http_code"
    done
fi

while IFS= read -r line; do
    printf 'HOOK_CHILD_INPUT:%s\n' "$line"
    if [ "$line" = "exit" ] || [ "$line" = "quit" ]; then
        break
    fi
done
]]
    return {
        ok = true,
        launch = {
            executable = "sh",
            argv = {"-c", script},
            environment = {},
            readiness = "none",
        },
    }
end

function M.dispatch(_: unknown): {[string]: unknown}
    return {ok = false, error = "fixture window never dispatches a structured turn"}
end

function M.normalize(_: unknown): {[string]: unknown}
    return {ok = false, error = "fixture window has no stream normalizer"}
end

function M.configure(_: unknown): {[string]: unknown}
    return {ok = true, configuration = nil}
end

return M
