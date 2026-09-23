-- MIT. An actual child submits hooks and remains interactive on its PTY.
local M = {}

local SCRIPT = [[
phase="$0"
sentinel="$HOME/window-hooks-sentinel"
if [ "$phase" = "continuation" ]; then
    marker=""
    if [ -f "$sentinel" ]; then IFS= read -r marker < "$sentinel"; fi
    if [ "$marker" != "window-hooks-retained" ]; then exit 41; fi
    printf 'HOOK_HOME_SENTINEL:retained\n'
else
    if [ -e "$sentinel" ]; then exit 42; fi
    printf 'window-hooks-retained\n' > "$sentinel"
    printf 'HOOK_HOME_SENTINEL:created\n'
fi

settings="$HOME/hook-url"
url=""
if [ -f "$settings" ]; then
    IFS= read -r url < "$settings"
fi

if [ -z "$BEE_GATEWAY_HOOK_TOKEN" ]; then
    printf 'HOOK_ERR:NO_TOKEN\n'
elif [ -z "$url" ]; then
    printf 'HOOK_ERR:NO_URL\n'
else
    if [ "$phase" != "continuation" ]; then
        start_payload='{"hook_event_name":"SessionStart","session_id":"s1","source":"startup"}'
        start_code=$(curl --max-time 5 -s -o /dev/null -w "%{http_code}" -X POST "$url" \
            -H "Authorization: Bearer $BEE_GATEWAY_HOOK_TOKEN" -H "Content-Type: application/json" \
            -d "$start_payload")
        printf 'HOOK_START_CODE:%s\n' "$start_code"
    fi
    if [ "$phase" = "continuation" ]; then
        payload='{"hook_event_name":"PreToolUse","session_id":"s1","prompt_id":"p2","tool_use_id":"toolu_2","tool_name":"Bash","tool_input":{"command":"echo continued"}}'
    else
        payload='{"hook_event_name":"PreToolUse","session_id":"s1","prompt_id":"p1","tool_use_id":"toolu_1","tool_name":"Bash","tool_input":{"command":"echo test"}}'
    fi
    for delivery in 1 2; do
    http_code=$(curl --max-time 5 -s -o /dev/null -w "%{http_code}" -X POST "$url" \
        -H "Authorization: Bearer $BEE_GATEWAY_HOOK_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload")
    printf 'HOOK_HTTP_CODE:%s\n' "$http_code"
    done
fi

while IFS= read -r line; do
    printf 'HOOK_CHILD_INPUT:%s\n' "$line"
    if [ "$line" = "pending-hook" ]; then
        pending_payload='{"hook_event_name":"PreToolUse","session_id":"s1","prompt_id":"pending","tool_use_id":"toolu_pending","tool_name":"Bash","tool_input":{"command":"echo accepted"}}'
        pending_code=$(curl --max-time 5 -s -o /dev/null -w "%{http_code}" -X POST "$url" \
            -H "Authorization: Bearer $BEE_GATEWAY_HOOK_TOKEN" -H "Content-Type: application/json" -d "$pending_payload")
        printf 'HOOK_PENDING_CODE:%s\n' "$pending_code"
    fi
    if [ "$line" = "exit" ] || [ "$line" = "quit" ]; then
        break
    fi
done
]]

local function launch(phase: string): {[string]: unknown}
    return {
        ok = true,
        launch = {
            executable = "sh",
            argv = {"-c", SCRIPT, phase},
            environment = {},
            readiness = "none",
        },
    }
end

function M.prepare(_: unknown): {[string]: unknown}
    return launch("initial")
end

function M.dispatch(value: unknown): {[string]: unknown}
    if type(value) ~= "table" then return {ok = false, error = "continuation request must be an object"} end
    local request = value :: {[string]: unknown}
    if request.brief ~= "" then return {ok = false, error = "continuation brief must be empty"} end
    if request.resume_ref ~= "s1" then return {ok = false, error = "continuation provider session must be s1"} end
    return launch("continuation")
end

function M.normalize(_: unknown): {[string]: unknown}
    return {ok = false, error = "fixture window has no stream normalizer"}
end

return M
