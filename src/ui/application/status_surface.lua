-- MIT. Bounded presentation values; decoding never grants thread access.
local M = {}
type Badge = {glyph: string, text: string, tone: string}
type Item = {tab_id: string, instance_id: string, thread_id: string, generation: integer,
    owner_authority: string, owner_incarnation: integer, badge: Badge}
type Snapshot = {revision: integer, items: {Item}}
local function text(value: unknown, limit: integer): string?
    if type(value) ~= "string" or #value > limit or value:find("%c") then return nil end
    return value
end
local function count(value: unknown): integer?
    if type(value) ~= "number" or value < 0 or value > 9007199254740990 or value ~= math.floor(value) then return nil end
    return math.floor(value)
end
local function badge(value: unknown): Badge?
    if type(value) ~= "table" then return nil end
    local availability = value.availability
    if availability ~= "loading" and availability ~= "unavailable" and availability ~= "ready" and availability ~= "stale" then return nil end
    if not count(value.revision) or not count(value.through_sequence) or not count(value.head_sequence) then return nil end
    local status = value.status
    local result: Badge = {glyph = "○", text = "Idle", tone = "muted"}
    if status ~= nil then
        if type(status) ~= "table" or type(status.waiting_on_you) ~= "boolean" then return nil end
        for _, key in ipairs({"open_requests", "pending_approvals", "running_actions", "uncertain_actions", "open_actions"}) do
            if not count(status[key]) then return nil end
        end
        if status.activity == "running" then result = {glyph = "●", text = "Busy", tone = "accent"}
        elseif status.activity == "waiting" then
            result = {glyph = "◐", text = status.waiting_on_you and "Waiting on you" or "Waiting", tone = status.waiting_on_you and "warning" or "muted"}
        elseif status.activity == "uncertain" then result = {glyph = "?", text = "Uncertain", tone = "warning"}
        elseif status.activity ~= "idle" then return nil end
        -- A completed turn is not evidence that the action succeeded. Only an
        -- owner receipt may supply a terminal badge, with no open actions left.
        local outcome = status.last_outcome
        if status.activity == "idle" and status.open_actions == 0 and type(outcome) == "table"
            and outcome.kind == "receipt" then
            local sequence = count(outcome.at_sequence)
            if not sequence or sequence == 0 then return nil end
            if outcome.outcome == "succeeded" then result = {glyph = "✓", text = "Succeeded", tone = "success"}
            elseif outcome.outcome == "failed" then result = {glyph = "!", text = "Failed", tone = "danger"}
            elseif outcome.outcome == "cancelled" then result = {glyph = "×", text = "Cancelled", tone = "muted"}
            elseif outcome.outcome == "uncertain" then result = {glyph = "?", text = "Uncertain", tone = "warning"}
            else return nil end
        end
        if status.waiting_on_you then result = {glyph = "◐", text = "Waiting on you", tone = "warning"} end
    elseif availability == "ready" or availability == "stale" then return nil end
    if availability == "loading" then return {glyph = "⟳", text = "Loading", tone = "muted"} end
    if availability == "unavailable" then
        return {glyph = "?", text = status ~= nil and ("Unavailable; last " .. result.text) or "Unavailable", tone = "muted"}
    end
    if availability == "stale" then return {glyph = "⟳", text = "Stale; " .. result.text, tone = "muted"} end
    return result
end
function M.decode(value: unknown): Snapshot?
    if type(value) ~= "table" or type(value.statuses) ~= "table" then return nil end
    local revision = count(value.status_revision)
    if not revision then return nil end
    local size = 0
    for key in pairs(value.statuses) do
        if type(key) ~= "number" or key < 1 or key > 16 or key ~= math.floor(key) then return nil end
        size = size + 1
    end
    local items: {Item} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, size do
        local raw = value.statuses[index]
        if type(raw) ~= "table" or type(raw.value) ~= "table" then return nil end
        local tab, instance = text(raw.tab_id, 80), text(raw.instance_id, 80)
        local thread, authority = text(raw.value.thread_id, 160), text(raw.value.owner_authority, 160)
        local generation, incarnation = count(raw.value.generation), count(raw.value.owner_incarnation)
        local summary = badge(raw.value)
        if not tab or tab == "" or not instance or instance == "" or not thread or thread == "" or not authority
            or not generation or not incarnation or not summary or seen[tab] then return nil end
        seen[tab] = true
        items[#items + 1] = {tab_id = tab, instance_id = instance, thread_id = thread, generation = generation,
            owner_authority = authority, owner_incarnation = incarnation, badge = summary}
    end
    return {revision = revision, items = items}
end
-- Client-to-presenter projection contains only bounded display values.
function M.presentation(value: unknown): Snapshot?
    if type(value) ~= "table" or type(value.items) ~= "table" then return nil end
    local revision = count(value.revision)
    if not revision then return nil end
    local size = 0
    for key in pairs(value.items) do
        if type(key) ~= "number" or key < 1 or key > 16 or key ~= math.floor(key) then return nil end
        size = size + 1
    end
    local items: {Item} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, size do
        local raw = value.items[index]
        if type(raw) ~= "table" or type(raw.badge) ~= "table" then return nil end
        local tab, instance = text(raw.tab_id, 80), text(raw.instance_id, 80)
        local thread, authority = text(raw.thread_id, 160), text(raw.owner_authority, 160)
        local generation, incarnation = count(raw.generation), count(raw.owner_incarnation)
        local glyph, label, tone = text(raw.badge.glyph, 8), text(raw.badge.text, 160), text(raw.badge.tone, 16)
        if not tab or tab == "" or not instance or instance == "" or not thread or thread == "" or not authority
            or not generation or not incarnation or not glyph or not label or not tone or seen[tab] then return nil end
        if tone ~= "muted" and tone ~= "accent" and tone ~= "warning" and tone ~= "danger" and tone ~= "success" then return nil end
        seen[tab] = true
        items[#items + 1] = {tab_id = tab, instance_id = instance, thread_id = thread, generation = generation,
            owner_authority = authority, owner_incarnation = incarnation, badge = {glyph = glyph, text = label, tone = tone}}
    end
    return {revision = revision, items = items}
end
return M
