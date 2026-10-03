#!/bin/sh
# SPDX-License-Identifier: MIT
# Deterministic protocol fixture; the only input file is its release FIFO.
case "$1" in
    --version) printf '%s\n' '2.1.265'; exit 0 ;;
    --help) printf '%s\n' '--permission-mode --model --effort --append-system-prompt-file'; exit 0 ;;
    auth) printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'; exit 0 ;;
esac
printf '%s\n' '{"type":"system","subtype":"init","session_id":"owner-journey-fixture"}'
for argument do
    case "$argument" in
        *JOURNEY_HIVE_APPROVAL*)
            printf '%s\n' '{"type":"control_request","request_id":"hive-tool-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"printf hive-approved"}},"session_id":"owner-journey-fixture"}'
            approved=false
            while IFS= read -r response; do
                case "$response" in
                    *'"request_id":"hive-tool-1"'*)
                        case "$response" in
                            *'"behavior":"allow"'*) approved=true; break ;;
                            *'"behavior":"deny"'*) exit 3 ;;
                        esac ;;
                esac
            done
            [ "$approved" = true ] || exit 4
            ;;
        *JOURNEY_GATE=*)
            gate=${argument##*JOURNEY_GATE=}
            case "$gate" in */.wippy/*) ;; *) exit 2 ;; esac
            IFS= read -r release < "$gate"
            ;;
    esac
done
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"OWNER JOURNEY STUB OUTPUT"}]}}'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"OWNER JOURNEY STUB OUTPUT","session_id":"owner-journey-fixture","usage":{"input_tokens":1,"output_tokens":1}}'
