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

# post EVENT PAYLOAD ROLE submits through the configured transport and prints
# ROLE with the transport result: the host-selected hook command's exit status
# for command hooks, the HTTP status of a direct endpoint POST otherwise.
post() {
    if [ -f "$HOME/hook-$1" ]; then
        IFS= read -r command < "$HOME/hook-$1"
        printf '%s' "$2" | sh -c "$command"
        printf '%s:exit-%s\n' "$3" "$?"
    else
        code=$(curl --max-time 5 -s -o /dev/null -w "%{http_code}" -X POST "$url" \
            -H "Authorization: Bearer $BEE_GATEWAY_HOOK_TOKEN" -H "Content-Type: application/json" -d "$2")
        printf '%s:http-%s\n' "$3" "$code"
    fi
}

if [ -z "$BEE_GATEWAY_HOOK_TOKEN" ]; then
    printf 'HOOK_ERR:NO_TOKEN\n'
elif [ -z "$url" ] && [ ! -f "$HOME/hook-PreToolUse" ]; then
    printf 'HOOK_ERR:NO_URL\n'
else
    if [ "$phase" != "continuation" ]; then
        post SessionStart '{"hook_event_name":"SessionStart","session_id":"s1","source":"startup"}' HOOK_START
    fi
    if [ "$phase" = "continuation" ]; then
        payload='{"hook_event_name":"PreToolUse","session_id":"s1","prompt_id":"p2","tool_use_id":"toolu_2","tool_name":"Bash","tool_input":{"command":"echo continued"}}'
    else
        payload='{"hook_event_name":"PreToolUse","session_id":"s1","prompt_id":"p1","tool_use_id":"toolu_1","tool_name":"Bash","tool_input":{"command":"echo test"}}'
    fi
    for delivery in 1 2; do
        post PreToolUse "$payload" HOOK_TOOL
    done
fi

while IFS= read -r line; do
    printf 'HOOK_CHILD_INPUT:%s\n' "$line"
    if [ "$line" = "pending-hook" ]; then
        pending_payload='{"hook_event_name":"PreToolUse","session_id":"s1","prompt_id":"pending","tool_use_id":"toolu_pending","tool_name":"Bash","tool_input":{"command":"echo accepted"}}'
        post PreToolUse "$pending_payload" HOOK_PENDING
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
