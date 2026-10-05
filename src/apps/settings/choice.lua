-- MIT. The appearance Settings shows: the node's confirmed appearance, or the
-- latest choice while a request for it is in flight. An announcement from the
-- node replaces the confirmed value only; the latest choice stays shown until
-- its own request settles, so earlier requests settling never step back.
local appearance = require("appearance")
type Choice = {confirmed: appearance.Preferences, pending: appearance.Preferences?, sequence: integer}
local M = {}

function M.new(confirmed: appearance.Preferences): Choice
    return {confirmed = confirmed, pending = nil, sequence = 0}
end

-- request records value as the latest choice and returns its sequence.
function M.request(choice: Choice, value: appearance.Preferences): integer
    choice.sequence = choice.sequence + 1
    choice.pending = value
    return choice.sequence
end

-- announced records the appearance the node announced.
function M.announced(choice: Choice, value: appearance.Preferences)
    choice.confirmed = value
end

-- settled ends request sequence; when it is the latest, the node's confirmed
-- appearance shows again (the chosen one when applied, the earlier when refused).
function M.settled(choice: Choice, sequence: integer, applied: boolean)
    if sequence ~= choice.sequence then return end
    if applied and choice.pending then choice.confirmed = choice.pending end
    choice.pending = nil
end

function M.shown(choice: Choice): appearance.Preferences
    return choice.pending or choice.confirmed
end
return M
