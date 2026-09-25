-- One shortcut classification for both press and release. Unclaimed keys are
-- application input, including Tab and unavailable optional launch shortcuts.
local M = {}
function M.action(key: string, key_type: string, ctrl: boolean, alt: boolean,
    initial: boolean, secondary: boolean, shift: boolean?): string
    if ctrl then
        if key == "q" then return "quit" end
        if key == "w" then return "close" end
        if key == "n" and initial then return "initial" end
        if key == "p" and secondary then return "secondary" end
    end
    if key_type == "f9" and alt then return "minimize" end
    if key_type == "f11" then return "fullscreen" end
    if key_type == "f1" then return "start" end
    if key_type == "f12" then return "rejoin" end
    if key_type == "tab" and alt then return shift and "previous" or "next" end
    return ""
end
return M
