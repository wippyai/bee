-- MIT. Pure decoder and reducer for records transported from bee.sync. Feed
-- adapters supply their own payload decoder; this layer verifies the common
-- owner, feed, cursor, revision and tombstone envelope before a UI folds it.
local bounds = require("bounds")
local M = {}
M.EVENT_SCHEMA = "bee.sync-event@1"
M.PROJECTION_SCHEMA = "bee.sync-projection@1"
M.PAGE_SCHEMA = "bee.sync-page@1"
M.SNAPSHOT_SCHEMA = "bee.sync-snapshot@1"
type Object = {[string]: unknown}
type PayloadDecoder = (unknown) -> (unknown?, string?)
type Event = {owner_id: string, feed: string, sequence: integer, event_id: string, event_type: string, payload: unknown,
    projection_key: string, revision: integer, tombstone: boolean, committed_at: string}
type Projection = {owner_id: string, feed: string, key: string, revision: integer, value: unknown, tombstone: boolean,
    sequence: integer, updated_at: string}
type Page = {owner_id: string, feed: string, events: {Event}, next_cursor: integer, more: boolean, head_cursor: integer,
    earliest_cursor: integer, scope_revision: string?}
type Snapshot = {owner_id: string, feed: string, items: {Projection}, next_key: string?, complete: boolean, cursor: integer,
    earliest_cursor: integer, scope_revision: string?}
type State = {owner_id: string, feed: string, cursor: integer, earliest_cursor: integer, projections: {[string]: Projection},
    snapshot_cursor: integer?, snapshot_after: string?, scope_revision: string?}
type EventReducer = (State, Event) -> (boolean?, string?)
local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do if type(key) ~= "string" then return nil end end
    return value :: Object
end
local function fields(value: Object, allowed: {string}): string?
    local known: {[string]: boolean} = {}
    for _, key in ipairs(allowed) do known[key] = true end
    for key in pairs(value) do if not known[key] then return "unknown field " .. key end end
    return nil
end
local function boolean(value: unknown): boolean?
    if type(value) ~= "boolean" then return nil end
    return value
end
local function line(value: unknown): string?
    if type(value) ~= "string" or value == "" or #value > bounds.MAX_ID_BYTES or value:find("%c") then return nil end
    return value
end
local function envelope(value: Object, schema: string, owner: string, feed: string): string?
    if value.schema ~= schema then return "sync schema is unsupported" end
    if value.owner_id ~= owner then return "sync owner does not match" end
    if value.feed ~= feed then return "sync feed does not match" end
    return nil
end
function M.event(value: unknown, owner: string, feed: string, decode_payload: PayloadDecoder?): (Event?, string?)
    local item = object(value)
    if not item then return nil, "sync event is not an object" end
    local unexpected = fields(item, {"schema", "owner_id", "feed", "sequence", "event_id", "event_type", "payload", "projection_key", "revision", "tombstone", "committed_at"})
    if unexpected then return nil, unexpected end
    local common = envelope(item, M.EVENT_SCHEMA, owner, feed)
    if common then return nil, common end
    local sequence, revision = bounds.count(item.sequence, 9007199254740991), bounds.count(item.revision, 9007199254740991)
    local event_id, event_type, projection_key, committed_at = bounds.id(item.event_id), bounds.id(item.event_type), bounds.id(item.projection_key), line(item.committed_at)
    local tombstone = boolean(item.tombstone)
    if not sequence or sequence < 1 or not revision or revision < 1 or not event_id or not event_type or not projection_key or not committed_at or tombstone == nil or item.payload == nil then
        return nil, "sync event has invalid fields"
    end
    local payload = item.payload
    if decode_payload then
        local decoded, decode_error = decode_payload(payload)
        if decoded == nil then return nil, decode_error or "sync event payload is invalid" end
        payload = decoded
    end
    return {owner_id = owner, feed = feed, sequence = sequence, event_id = event_id, event_type = event_type, payload = payload,
        projection_key = projection_key, revision = revision, tombstone = tombstone, committed_at = committed_at}, nil
end
function M.projection(value: unknown, owner: string, feed: string, decode_value: PayloadDecoder?): (Projection?, string?)
    local item = object(value)
    if not item then return nil, "sync projection is not an object" end
    local unexpected = fields(item, {"schema", "owner_id", "feed", "key", "revision", "value", "tombstone", "sequence", "updated_at"})
    if unexpected then return nil, unexpected end
    local common = envelope(item, M.PROJECTION_SCHEMA, owner, feed)
    if common then return nil, common end
    local key, updated_at = bounds.id(item.key), line(item.updated_at)
    local revision, sequence = bounds.count(item.revision, 9007199254740991), bounds.count(item.sequence, 9007199254740991)
    local tombstone = boolean(item.tombstone)
    if not key or not updated_at or not revision or revision < 1 or not sequence or sequence < 1 or tombstone == nil then return nil, "sync projection has invalid fields" end
    if tombstone then
        if item.value ~= nil then return nil, "sync tombstone has a value" end
        return {owner_id = owner, feed = feed, key = key, revision = revision, value = nil, tombstone = true, sequence = sequence, updated_at = updated_at}, nil
    end
    if item.value == nil then return nil, "sync projection has no value" end
    local decoded = item.value
    if decode_value then
        local decode_error: string?
        decoded, decode_error = decode_value(item.value)
        if decoded == nil then return nil, decode_error or "sync projection value is invalid" end
    end
    return {owner_id = owner, feed = feed, key = key, revision = revision, value = decoded, tombstone = false, sequence = sequence, updated_at = updated_at}, nil
end
local function list(value: unknown): {unknown}?
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil end
        count = count + 1
    end
    if count > bounds.MAX_PAGE then return nil end
    local result: {unknown} = {}
    for index = 1, count do
        if value[index] == nil then return nil end
        result[index] = value[index]
    end
    return result
end
function M.page(value: unknown, owner: string, feed: string, decode_payload: PayloadDecoder?): (Page?, string?)
    local item = object(value)
    if not item then return nil, "sync page is not an object" end
    local unexpected = fields(item, {"schema", "owner_id", "feed", "events", "next_cursor", "more", "head_cursor", "earliest_cursor", "scope_revision", "reset_required"})
    if unexpected then return nil, unexpected end
    local common = envelope(item, M.PAGE_SCHEMA, owner, feed)
    if common then return nil, common end
    if item.reset_required ~= false then return nil, "sync page requires reset" end
    local raw_events = list(item.events)
    local next, head, earliest = bounds.count(item.next_cursor, 9007199254740991), bounds.count(item.head_cursor, 9007199254740991), bounds.count(item.earliest_cursor, 9007199254740991)
    local more = boolean(item.more)
    local scope_revision: string? = nil
    if item.scope_revision ~= nil then
        scope_revision = bounds.id(item.scope_revision)
        if not scope_revision then return nil, "sync page scope_revision is invalid" end
    end
    if not raw_events or next == nil or head == nil or earliest == nil or more == nil or earliest > head or next > head then return nil, "sync page has invalid fields" end
    local events: {Event} = {}
    local prior = 0
    for index, raw in ipairs(raw_events) do
        local event, event_error = M.event(raw, owner, feed, decode_payload)
        if not event then return nil, event_error end
        if event.sequence <= prior then return nil, "sync page is not ordered" end
        prior = event.sequence
        events[index] = event
    end
    if #events > 0 and events[#events].sequence > next then return nil, "sync page cursor precedes events" end
    local page: Page = {owner_id = owner, feed = feed, events = events, next_cursor = next :: integer,
        more = more :: boolean, head_cursor = head :: integer, earliest_cursor = earliest :: integer,
        scope_revision = scope_revision}
    return page, nil
end
function M.snapshot(value: unknown, owner: string, feed: string, decode_value: PayloadDecoder?): (Snapshot?, string?)
    local item = object(value)
    if not item then return nil, "sync snapshot is not an object" end
    local unexpected = fields(item, {"schema", "owner_id", "feed", "items", "next_key", "complete", "cursor", "earliest_cursor", "scope_revision", "reset_required"})
    if unexpected then return nil, unexpected end
    local common = envelope(item, M.SNAPSHOT_SCHEMA, owner, feed)
    if common then return nil, common end
    if item.reset_required ~= false then return nil, "sync snapshot requires reset" end
    local raw_items = list(item.items)
    local cursor, earliest = bounds.count(item.cursor, 9007199254740991), bounds.count(item.earliest_cursor, 9007199254740991)
    local complete = boolean(item.complete)
    local next_key: string? = nil
    local scope_revision: string? = nil
    if item.next_key ~= nil then next_key = bounds.id(item.next_key) end
    if item.scope_revision ~= nil then
        scope_revision = bounds.id(item.scope_revision)
        if not scope_revision then return nil, "sync snapshot scope_revision is invalid" end
    end
    if not raw_items or cursor == nil or earliest == nil or earliest > cursor or complete == nil or (not complete and not next_key) or (complete and next_key ~= nil) then return nil, "sync snapshot has invalid fields" end
    local items: {Projection} = {}
    local prior = ""
    for index, raw in ipairs(raw_items) do
        local projection, projection_error = M.projection(raw, owner, feed, decode_value)
        if not projection then return nil, projection_error end
        if projection.key <= prior then return nil, "sync snapshot is not ordered" end
        prior = projection.key
        items[index] = projection
    end
    if next_key and #items > 0 and next_key ~= items[#items].key then return nil, "sync snapshot key does not match items" end
    local snapshot: Snapshot = {owner_id = owner, feed = feed, items = items, next_key = next_key,
        complete = complete :: boolean, cursor = cursor :: integer, earliest_cursor = earliest :: integer,
        scope_revision = scope_revision}
    return snapshot, nil
end
function M.new(owner: string, feed: string): State
    local state: State = {owner_id = owner, feed = feed, cursor = 0, earliest_cursor = 0, projections = {},
        snapshot_cursor = nil, snapshot_after = nil, scope_revision = nil}
    return state
end
local function fold(state: State, projection: Projection): boolean
    local current = state.projections[projection.key]
    if current and current.revision >= projection.revision then return false end
    state.projections[projection.key] = projection
    return true
end
function M.fold_projection(state: State, projection: Projection): boolean
    return fold(state, projection)
end
local function copy_state(state: State): State
    local projections: {[string]: Projection} = {}
    for key, value in pairs(state.projections) do projections[key] = value end
    return {owner_id = state.owner_id, feed = state.feed, cursor = state.cursor, earliest_cursor = state.earliest_cursor,
        projections = projections, snapshot_cursor = state.snapshot_cursor, snapshot_after = state.snapshot_after,
        scope_revision = state.scope_revision}
end
local function commit_state(destination: State, source: State)
    destination.cursor, destination.earliest_cursor, destination.projections = source.cursor, source.earliest_cursor, source.projections
    destination.snapshot_cursor, destination.snapshot_after, destination.scope_revision = source.snapshot_cursor, source.snapshot_after, source.scope_revision
end
function M.apply_page(state: State, page: Page, reduce_event: EventReducer?): (boolean?, string?)
    if state.snapshot_cursor ~= nil then return nil, "finish snapshot before reading events" end
    if page.owner_id ~= state.owner_id or page.feed ~= state.feed then return nil, "sync page belongs to another feed" end
    if state.cursor < page.earliest_cursor then return nil, "sync state requires reset" end
    if state.scope_revision ~= nil and page.scope_revision ~= state.scope_revision then return nil, "sync page scope changed" end
    local working = copy_state(state)
    if working.scope_revision == nil then working.scope_revision = page.scope_revision end
    local changed = false
    local prior = working.cursor
    for _, event in ipairs(page.events) do
        -- Feed adapters may apply an authorized filter. The cursor still
        -- advances over invisible records, so visible event sequence values
        -- need only increase; they need not be consecutive.
        if event.sequence <= prior or event.sequence > page.next_cursor then return nil, "sync event is outside the page cursor" end
        prior = event.sequence
        if reduce_event then
            local did_change, reduce_error = reduce_event(working, event)
            if did_change == nil then return nil, reduce_error or "sync event reducer failed" end
            if did_change then changed = true end
        end
    end
    if page.next_cursor < working.cursor then return nil, "sync page moves cursor backwards" end
    -- Invisible trailing events still advance the owner's scan cursor.
    if page.next_cursor < prior then return nil, "sync page cursor precedes events" end
    working.cursor, working.earliest_cursor = page.next_cursor, page.earliest_cursor
    commit_state(state, working)
    return changed, nil
end
function M.apply_snapshot(state: State, snapshot: Snapshot): (boolean?, string?)
    if snapshot.owner_id ~= state.owner_id or snapshot.feed ~= state.feed then return nil, "sync snapshot belongs to another feed" end
    if state.snapshot_cursor == nil then
        state.snapshot_cursor = snapshot.cursor
        state.snapshot_after = ""
        state.projections = {}
        state.scope_revision = snapshot.scope_revision
    elseif state.snapshot_cursor ~= snapshot.cursor then
        return nil, "sync snapshot cursor changed"
    elseif state.scope_revision ~= snapshot.scope_revision then
        return nil, "sync snapshot scope changed"
    end
    local changed = false
    for _, projection in ipairs(snapshot.items) do if fold(state, projection) then changed = true end end
    state.snapshot_after = snapshot.next_key
    if snapshot.complete then
        state.cursor = snapshot.cursor
        state.earliest_cursor = snapshot.earliest_cursor
        state.snapshot_cursor, state.snapshot_after = nil, nil
    end
    return changed, nil
end
function M.reset(state: State)
    state.cursor, state.earliest_cursor, state.projections, state.snapshot_cursor, state.snapshot_after, state.scope_revision = 0, 0, {}, nil, nil, nil
end
return M
