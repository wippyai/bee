-- MIT. The public sessions client for Lua applications and tools. It calls the
-- bee.sessions owner contracts as the calling process's own actor and returns
-- typed values or a typed Fault; it grants no authority and selects no identity.
--
-- Every mutation carries a caller-owned operation key. Bee does not expose a
-- durable application event identity to this client, so keys are explicit.
local contract = require("contract")
local bounds = require("bounds")
local protocol = require("protocol")
local M = {}

M.SESSIONS = "bee.sessions:contract"
M.CATALOG = "bee.sessions:catalog"

type Fault = protocol.Fault
type WorkAwait = protocol.WorkAwait
type OperationAwait = protocol.OperationAwait
type AnyAwait = protocol.AnyAwait
type JoinAwait = protocol.JoinAwait
type Input = string | {schema: string, value: unknown}
type ProfileRef = {id: string, revision: integer}
type Addressed = {incarnation: integer, ref: (unknown) -> string}
type Observable = {ref: (unknown) -> string}
type WorkArg = string | Addressed
type SessionArg = string | Addressed
type JoinPolicy = "all_success" | "all_settled" | "first_success" | "quorum"
type CatalogKind = "definition" | "profile"

type AwaitOptions = {timeout_ms: integer?}
type CancelOptions = {work: WorkArg?, incarnation: integer?, reason: string?, operation_key: string}
type CloseOptions = {session: SessionArg?, incarnation: integer?, operation_key: string}
type SendOptions = {session: SessionArg?, incarnation: integer?, input: Input, output: string?, operation_key: string}
type OpenOptions = {presentation: protocol.Presentation?, definition: string, profile: ProfileRef?, workdir: string?, workspace: string?, operation_key: string}
type CallOptions = {presentation: protocol.Presentation?, definition: string, profile: ProfileRef?, workdir: string?, workspace: string?, input: Input, output: string?,
    timeout_ms: integer?, operation_key: string}
type ClientAwaitOptions = {subject: string | Observable, timeout_ms: integer?}
type JoinOptions = {works: {WorkArg}, policy: JoinPolicy?, quorum: integer?, timeout_ms: integer?,
    operation_key: string}
type ListOptions = {filter: {lifecycle: string?, activity: string?, workspace: string?, definition: string?}?, cursor: string?}
type HistoryOptions = {session: string, cursor: integer?, limit: integer?}
type CatalogOptions = {kind: CatalogKind?, include_unavailable: boolean?, cursor: string?}

type Operation = {receipt: protocol.ControlReceipt, ref: (Operation) -> string,
    await: (Operation, AwaitOptions?) -> (OperationAwait?, Fault?)}
type Work = {receipt: protocol.WorkReceipt?, session: string, incarnation: integer, ref: (Work) -> string,
    await: (Work, AwaitOptions?) -> (WorkAwait?, Fault?),
    cancel: (Work, CancelOptions) -> (Operation?, Fault?),
    state: (Work) -> (protocol.WorkState?, Fault?)}
type Session = {receipt: protocol.OpenReceipt?, snapshot: protocol.SessionSnapshot, incarnation: integer,
    ref: (Session) -> string,
    send: (Session, SendOptions) -> (Work?, Fault?),
    await: (Session, Work, AwaitOptions?) -> (WorkAwait?, Fault?),
    close: (Session, CloseOptions) -> (Operation?, Fault?),
    get: (Session) -> (Session?, Fault?),
    history: (Session, {cursor: integer?, limit: integer?}?) -> (protocol.HistoryPage?, Fault?)}
type Call = {work: Work, observation: WorkAwait}

type Client = {
    open: (Client, OpenOptions) -> (Session?, Fault?),
    call: (Client, CallOptions) -> (Call?, Fault?),
    send: (Client, SendOptions) -> (Work?, Fault?),
    cancel: (Client, CancelOptions) -> (Operation?, Fault?),
    close: (Client, CloseOptions) -> (Operation?, Fault?),
    await: (Client, ClientAwaitOptions) -> (AnyAwait?, Fault?),
    join: (Client, JoinOptions) -> (JoinAwait?, Fault?),
    get: (Client, string) -> (Session?, Fault?),
    work: (Client, string) -> (Work?, Fault?),
    list: (Client, ListOptions?) -> (protocol.ListPage?, Fault?),
    history: (Client, HistoryOptions) -> (protocol.HistoryPage?, Fault?),
    catalog: (Client, CatalogOptions?) -> (protocol.CatalogPage?, Fault?),
}

local function fault(code: string, message: string, retry: protocol.Retry, key: string?): Fault
    return protocol.fault(code, message, retry, key)
end

local function invalid(message: string): Fault
    return fault("INVALID", message, "never", nil)
end

local function call_owner(id: string, method: string, request: {[string]: unknown}): (unknown, string?)
    local definition, get_error = contract.get(id)
    if not definition then return nil, "contract " .. id .. ": " .. tostring(get_error) end
    local instance, open_error = definition:open()
    if not instance then return nil, "open " .. id .. ": " .. tostring(open_error) end
    local entry = (instance :: {[string]: unknown})[method]
    if type(entry) ~= "function" then return nil, id .. " has no method " .. method end
    local raw, call_error = (entry :: (unknown, unknown) -> (unknown, unknown))(instance, request)
    if call_error ~= nil then return nil, tostring(call_error) end
    return raw, nil
end

-- The owner's ok value, its own Fault, or a transport/shape Fault. A lost or
-- malformed reply to a mutation is an unknown outcome to recover by key.
local function invoke(id: string, method: string, request: {[string]: unknown}, key: string?): (unknown, Fault?)
    local raw, transport = call_owner(id, method, request)
    if transport ~= nil then
        if key then return nil, fault("UNKNOWN_OUTCOME", transport, "same_key", key) end
        return nil, fault("UNAVAILABLE", transport, "refresh", nil)
    end
    local reply, reply_error = protocol.decode_reply(raw)
    if not reply then
        if key then return nil, fault("UNKNOWN_OUTCOME", tostring(reply_error), "same_key", key) end
        return nil, fault("UNAVAILABLE", tostring(reply_error), "refresh", nil)
    end
    if not reply.ok then return nil, reply.error end
    return reply.value, nil
end

local function unreadable(message: string?, key: string?): Fault
    if key then return fault("UNKNOWN_OUTCOME", tostring(message), "same_key", key) end
    return fault("UNAVAILABLE", tostring(message), "refresh", nil)
end

local function operation_key(explicit: unknown): (string?, Fault?)
    if explicit == nil then
        return nil, fault("KEY_REQUIRED", "pass an explicit operation_key for every mutation", "never", nil)
    end
    local supplied = protocol.key(explicit)
    if not supplied then return nil, invalid("operation_key must be nonempty bounded text without control characters") end
    return supplied, nil
end

-- The ref of a string or handle argument, checked against the expected kind.
local function ref_of(value: unknown, kind: "session" | "work"): (string?, Fault?)
    local ref: string? = nil
    if type(value) == "string" then
        ref = value
    elseif type(value) == "table" then
        local accessor = (value :: {[string]: unknown}).ref
        if type(accessor) == "function" then
            local produced = (accessor :: (unknown) -> unknown)(value)
            if type(produced) == "string" then ref = produced end
        end
    end
    local checked = ref and protocol.ref(kind, ref)
    if not checked then return nil, invalid(kind .. " must be a " .. kind .. " ref or handle") end
    return checked, nil
end

local function timeout_of(value: unknown): (integer?, Fault?)
    if value == nil then return nil, nil end
    local number = bounds.count(value)
    if not number or number > protocol.MAX_TIMEOUT_MS then
        return nil, invalid("timeout_ms must be an integer from 0 to " .. tostring(protocol.MAX_TIMEOUT_MS))
    end
    return number, nil
end

local function input_of(value: unknown): (unknown, Fault?)
    if type(value) == "string" then
        if #value > protocol.MAX_TEXT_BYTES then return nil, invalid("input text exceeds " .. tostring(protocol.MAX_TEXT_BYTES) .. " bytes") end
        return value, nil
    end
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"schema", "value"}) then return nil, invalid("input must be text or {schema, value}") end
    local schema = protocol.any_ref(object.schema)
    if not schema or not protocol.json(object.value) then
        return nil, invalid("input needs a schema ref and a JSON value within 64 KiB and depth 16")
    end
    return {schema = schema, value = object.value}, nil
end

local function output_of(value: unknown): (string?, Fault?)
    if value == nil then return nil, nil end
    local output = protocol.any_ref(value)
    if not output then return nil, invalid("output must be a schema ref") end
    return output, nil
end

local function spec_of(definition: unknown, profile: unknown, workdir: unknown, workspace: unknown, presentation: unknown): ({[string]: unknown}?, Fault?)
    local ref = protocol.any_ref(definition)
    if not ref then return nil, invalid("definition must be a ref") end
    local spec: {[string]: unknown} = {definition = ref}
    if profile ~= nil then
        local object = bounds.object(profile)
        local id = object and protocol.any_ref(object.id)
        local revision = object and protocol.position(object.revision)
        if not object or bounds.fields(object, {"id", "revision"}) or not id or not revision then
            return nil, invalid("profile must be {id, revision}")
        end
        spec.profile = {id = id, revision = revision}
    end
    if workdir ~= nil then
        local folder = protocol.any_ref(workdir)
        if not folder then return nil, invalid("workdir must be a resource ref") end
        spec.workdir = folder
    end
    if workspace ~= nil then
        if type(workspace) ~= "string" or #workspace ~= 32 or workspace:find("[^0-9a-f]") then return nil, invalid("workspace must be a canonical workspace ID") end
        spec.workspace = workspace
    end
    if presentation ~= nil then
        if presentation ~= "headless" and presentation ~= "window" then return nil, invalid("presentation must be headless or window") end
        spec.presentation = presentation
    end
    return spec, nil
end

local function incarnation_of(explicit: unknown, handle: unknown): (integer?, Fault?)
    local value = explicit
    if type(handle) == "table" then value = (handle :: {[string]: unknown}).incarnation end
    if value == nil then return nil, nil end
    local number = protocol.position(value)
    if not number then return nil, invalid("incarnation must be a positive integer") end
    return number, nil
end

local function new_client(): Client
    local client: Client = {} :: Client

    local function observe(ref: string, timeout: unknown): (unknown, Fault?)
        local milliseconds, timeout_fault = timeout_of(timeout)
        if timeout_fault then return nil, timeout_fault end
        return invoke(M.SESSIONS, "await", {subject = ref, timeout_ms = milliseconds}, nil)
    end

    local function operation_handle(receipt: protocol.ControlReceipt): Operation
        local ref = receipt.operation
        local handle: Operation = {} :: Operation
        handle.receipt = receipt
        handle.ref = function(_: Operation): string return ref end
        handle.await = function(_: Operation, options: AwaitOptions?): (OperationAwait?, Fault?)
            local value, failure = observe(ref, options and options.timeout_ms)
            if failure then return nil, failure end
            local observed, decode_error = protocol.decode_operation_await(value)
            if not observed then return nil, unreadable(decode_error, nil) end
            if observed.subject ~= ref then return nil, unreadable("await answered another subject", nil) end
            return observed, nil
        end
        return handle
    end

    local function work_handle(ref: string, session: string, incarnation: integer, receipt: protocol.WorkReceipt?): Work
        local handle: Work = {} :: Work
        handle.receipt = receipt
        handle.session = session
        handle.incarnation = incarnation
        handle.ref = function(_: Work): string return ref end
        handle.await = function(_: Work, options: AwaitOptions?): (WorkAwait?, Fault?)
            local value, failure = observe(ref, options and options.timeout_ms)
            if failure then return nil, failure end
            local observed, decode_error = protocol.decode_work_await(value)
            if not observed then return nil, unreadable(decode_error, nil) end
            if observed.subject ~= ref then return nil, unreadable("await answered another subject", nil) end
            return observed, nil
        end
        handle.cancel = function(_: Work, options: CancelOptions): (Operation?, Fault?)
            local request: CancelOptions = {work = ref, incarnation = incarnation, reason = options and options.reason,
                operation_key = options.operation_key}
            return client:cancel(request)
        end
        handle.state = function(_: Work): (protocol.WorkState?, Fault?)
            local value, failure = invoke(M.SESSIONS, "get", {work = ref}, nil)
            if failure then return nil, failure end
            local decoded, decode_error = protocol.decode_get(value)
            if not decoded or decoded.kind ~= "work" or decoded.value.work ~= ref then
                return nil, unreadable(decode_error or "get answered another subject", nil)
            end
            return decoded.value, nil
        end
        return handle
    end

    local function session_handle(snapshot: protocol.SessionSnapshot, receipt: protocol.OpenReceipt?): Session
        local handle: Session = {} :: Session
        handle.receipt = receipt
        handle.snapshot = snapshot
        handle.incarnation = snapshot.incarnation
        handle.ref = function(_: Session): string return snapshot.session end
        handle.send = function(_: Session, options: SendOptions): (Work?, Fault?)
            local request: SendOptions = {session = snapshot.session, incarnation = snapshot.incarnation,
                input = options.input, output = options.output, operation_key = options.operation_key}
            return client:send(request)
        end
        handle.await = function(_: Session, work: Work, options: AwaitOptions?): (WorkAwait?, Fault?)
            if work.session ~= snapshot.session then
                return nil, invalid("work " .. work:ref() .. " does not belong to session " .. snapshot.session)
            end
            return work:await(options)
        end
        handle.close = function(_: Session, options: CloseOptions): (Operation?, Fault?)
            local request: CloseOptions = {session = snapshot.session, incarnation = snapshot.incarnation,
                operation_key = options.operation_key}
            return client:close(request)
        end
        handle.get = function(_: Session): (Session?, Fault?)
            return client:get(snapshot.session)
        end
        handle.history = function(_: Session, options: {cursor: integer?, limit: integer?}?): (protocol.HistoryPage?, Fault?)
            return client:history({session = snapshot.session, cursor = options and options.cursor, limit = options and options.limit})
        end
        return handle
    end

    -- Opens a session with its first work in one owner operation.
    local function run(options: CallOptions): (Work?, Fault?)
        local spec, spec_fault = spec_of(options.definition, options.profile, options.workdir, options.workspace, options.presentation)
        if not spec then return nil, spec_fault end
        local input, input_fault = input_of(options.input)
        if input == nil then return nil, input_fault end
        local output, output_fault = output_of(options.output)
        if output_fault then return nil, output_fault end
        local request: {[string]: unknown} = {spec = spec, input = input, output = output}
        local key, key_fault = operation_key(options.operation_key)
        if not key then return nil, key_fault end
        request.operation_key = key
        local value, failure = invoke(M.SESSIONS, "run", request, key)
        if failure then return nil, failure end
        local receipt, decode_error = protocol.decode_work_receipt(value)
        if not receipt then return nil, unreadable(decode_error, key) end
        return work_handle(receipt.work, receipt.session, 1, receipt), nil
    end

    client.open = function(_: Client, options: OpenOptions): (Session?, Fault?)
        local spec, spec_fault = spec_of(options.definition, options.profile, options.workdir, options.workspace, options.presentation)
        if not spec then return nil, spec_fault end
        local request: {[string]: unknown} = {spec = spec}
        local key, key_fault = operation_key(options.operation_key)
        if not key then return nil, key_fault end
        request.operation_key = key
        local value, failure = invoke(M.SESSIONS, "open", request, key)
        if failure then return nil, failure end
        local receipt, decode_error = protocol.decode_open_receipt(value)
        if not receipt then return nil, unreadable(decode_error, key) end
        return session_handle(receipt.snapshot, receipt), nil
    end

    client.call = function(_: Client, options: CallOptions): (Call?, Fault?)
        local timeout, timeout_fault = timeout_of(options.timeout_ms)
        if timeout_fault then return nil, timeout_fault end
        local work, run_fault = run(options)
        if not work then return nil, run_fault end
        local observation, await_fault = work:await({timeout_ms = timeout or protocol.DEFAULT_TIMEOUT_MS})
        if not observation then return nil, await_fault end
        return {work = work, observation = observation}, nil
    end

    client.send = function(_: Client, options: SendOptions): (Work?, Fault?)
        local session, session_fault = ref_of(options.session, "session")
        if not session then return nil, session_fault end
        local input, input_fault = input_of(options.input)
        if input == nil then return nil, input_fault end
        local output, output_fault = output_of(options.output)
        if output_fault then return nil, output_fault end
        local incarnation, incarnation_fault = incarnation_of(options.incarnation, options.session)
        if incarnation_fault then return nil, incarnation_fault end
        local request: {[string]: unknown} = {session = session, input = input, output = output,
            expected_incarnation = incarnation}
        local key, key_fault = operation_key(options.operation_key)
        if not key then return nil, key_fault end
        request.operation_key = key
        local value, failure = invoke(M.SESSIONS, "send", request, key)
        if failure then return nil, failure end
        local receipt, decode_error = protocol.decode_work_receipt(value)
        if not receipt then return nil, unreadable(decode_error, key) end
        if receipt.session ~= session then return nil, unreadable("send receipt names another session", key) end
        return work_handle(receipt.work, receipt.session, incarnation or 1, receipt), nil
    end

    client.cancel = function(_: Client, options: CancelOptions): (Operation?, Fault?)
        local work, work_fault = ref_of(options.work, "work")
        if not work then return nil, work_fault end
        local reason: string? = nil
        if options.reason ~= nil then
            reason = bounds.text(options.reason, protocol.MAX_TEXT_BYTES)
            if not reason then return nil, invalid("reason must be text of at most " .. tostring(protocol.MAX_TEXT_BYTES) .. " bytes") end
        end
        local incarnation, incarnation_fault = incarnation_of(options.incarnation, options.work)
        if incarnation_fault then return nil, incarnation_fault end
        local request: {[string]: unknown} = {work = work, reason = reason, expected_incarnation = incarnation}
        local key, key_fault = operation_key(options.operation_key)
        if not key then return nil, key_fault end
        request.operation_key = key
        local value, failure = invoke(M.SESSIONS, "cancel", request, key)
        if failure then return nil, failure end
        local receipt, decode_error = protocol.decode_control_receipt(value)
        if not receipt then return nil, unreadable(decode_error, key) end
        if receipt.effect ~= "cancel" or receipt.subject ~= work then return nil, unreadable("cancel receipt names another effect or subject", key) end
        return operation_handle(receipt), nil
    end

    client.close = function(_: Client, options: CloseOptions): (Operation?, Fault?)
        if (options :: {[string]: unknown}).mode ~= nil then return nil, invalid("close does not accept a mode") end
        local session, session_fault = ref_of(options.session, "session")
        if not session then return nil, session_fault end
        local incarnation, incarnation_fault = incarnation_of(options.incarnation, options.session)
        if incarnation_fault then return nil, incarnation_fault end
        local request: {[string]: unknown} = {session = session, expected_incarnation = incarnation}
        local key, key_fault = operation_key(options.operation_key)
        if not key then return nil, key_fault end
        request.operation_key = key
        local value, failure = invoke(M.SESSIONS, "close", request, key)
        if failure then return nil, failure end
        local receipt, decode_error = protocol.decode_control_receipt(value)
        if not receipt then return nil, unreadable(decode_error, key) end
        if receipt.effect ~= "close" or receipt.subject ~= session then return nil, unreadable("close receipt names another effect or subject", key) end
        return operation_handle(receipt), nil
    end

    client.await = function(_: Client, options: ClientAwaitOptions): (AnyAwait?, Fault?)
        local subject = options.subject
        local ref: string? = nil
        if type(subject) == "string" then
            ref = subject
        else
            local produced = subject.ref(subject)
            if type(produced) == "string" then ref = produced end
        end
        local kind = ref and protocol.subject_kind(ref)
        if not ref or not kind then return nil, invalid("subject must be a work or operation ref or handle") end
        local value, failure = observe(ref, options.timeout_ms)
        if failure then return nil, failure end
        local observed, decode_error = protocol.decode_any_await(value)
        if not observed then return nil, unreadable(decode_error, nil) end
        if observed.subject ~= ref or observed.subject_kind ~= kind then return nil, unreadable("await answered another subject", nil) end
        return observed, nil
    end

    client.join = function(_: Client, options: JoinOptions): (JoinAwait?, Fault?)
        if (options :: {[string]: unknown}).losers ~= nil then return nil, invalid("join does not accept a losers option") end
        local rows = bounds.array(options.works, protocol.MAX_ITEMS)
        if not rows or #rows < 1 then return nil, invalid("works must hold 1 to 64 work refs") end
        local works: {string} = {}
        local seen: {[string]: boolean} = {}
        for index, raw in ipairs(rows) do
            local work, work_fault = ref_of(raw, "work")
            if not work then return nil, work_fault end
            if seen[work] then return nil, invalid("works repeats " .. work) end
            seen[work] = true
            works[index] = work
        end
        local policy = options.policy
        if policy ~= nil and policy ~= "all_success" and policy ~= "all_settled" and policy ~= "first_success" and policy ~= "quorum" then
            return nil, invalid("policy is invalid")
        end
        if (policy == "quorum") ~= (options.quorum ~= nil) then return nil, invalid("quorum is required exactly for the quorum policy") end
        local quorum: integer? = nil
        if options.quorum ~= nil then
            quorum = protocol.position(options.quorum)
            if not quorum or quorum > #works then return nil, invalid("quorum must be from 1 to the number of works") end
        end
        local timeout, timeout_fault = timeout_of(options.timeout_ms)
        if timeout_fault then return nil, timeout_fault end
        local request: {[string]: unknown} = {works = works, policy = policy, quorum = quorum}
        local key, key_fault = operation_key(options.operation_key)
        if not key then return nil, key_fault end
        request.operation_key = key
        request.timeout_ms = timeout
        local value, failure = invoke(M.SESSIONS, "join", request, key)
        if failure then return nil, failure end
        local joined, decode_error = protocol.decode_join_await(value)
        if not joined then return nil, unreadable(decode_error, key) end
        if #joined.children ~= #works then return nil, unreadable("join answered another child set", key) end
        for index, child in ipairs(joined.children) do
            if child.subject ~= works[index] then return nil, unreadable("join children do not follow the input order", key) end
        end
        return joined, nil
    end

    client.get = function(_: Client, ref: string): (Session?, Fault?)
        local session = protocol.ref("session", ref)
        if not session then return nil, invalid("session must be a session ref") end
        local value, failure = invoke(M.SESSIONS, "get", {session = session}, nil)
        if failure then return nil, failure end
        local decoded, decode_error = protocol.decode_get(value)
        if not decoded or decoded.kind ~= "session" or decoded.value.session ~= session then
            return nil, unreadable(decode_error or "get answered another subject", nil)
        end
        return session_handle(decoded.value, nil), nil
    end

    client.work = function(_: Client, ref: string): (Work?, Fault?)
        local work = protocol.ref("work", ref)
        if not work then return nil, invalid("work must be a work ref") end
        local value, failure = invoke(M.SESSIONS, "get", {work = work}, nil)
        if failure then return nil, failure end
        local decoded, decode_error = protocol.decode_get(value)
        if not decoded or decoded.kind ~= "work" or decoded.value.work ~= work then
            return nil, unreadable(decode_error or "get answered another subject", nil)
        end
        local owner, owner_fault = client:get(decoded.value.session)
        if not owner then return nil, owner_fault end
        return work_handle(work, decoded.value.session, owner.incarnation, nil), nil
    end

    client.history = function(_: Client, options: HistoryOptions): (protocol.HistoryPage?, Fault?)
        local session = protocol.ref("session", options.session)
        local cursor = options.cursor == nil and nil or bounds.count(options.cursor)
        local limit = options.limit == nil and 64 or protocol.position(options.limit)
        if not session or (options.cursor ~= nil and cursor == nil) or not limit or limit > 64 then return nil, invalid("history requires a session and bounded cursor/limit") end
        local value, failure = invoke(M.SESSIONS, "history", {session = session, cursor = cursor, limit = limit}, nil)
        if failure then return nil, failure end
        local page, decode_error = protocol.decode_history(value)
        if not page then return nil, unreadable(decode_error, nil) end
        return page, nil
    end

    client.list = function(_: Client, options: ListOptions?): (protocol.ListPage?, Fault?)
        local request: {[string]: unknown} = {}
        if options and options.filter ~= nil then
            local filter = bounds.object(options.filter)
            if not filter or bounds.fields(filter, {"lifecycle", "activity", "workspace", "definition"}) then return nil, invalid("filter is malformed") end
            local allowed: {[string]: {string}} = {lifecycle = {"opening", "active", "suspended", "closing", "closed"},
                activity = {"idle", "working", "blocked", "stalled"}}
            for name, raw in pairs(filter) do
                local matched = (name == "workspace" or name == "definition") and bounds.id(raw) ~= nil
                for _, item in ipairs(allowed[name] or {}) do if item == raw then matched = true end end
                if not matched then return nil, invalid("filter " .. name .. " is invalid") end
            end
            request.filter = filter
        end
        if options and options.cursor ~= nil then
            local cursor = protocol.cursor(options.cursor)
            if not cursor then return nil, invalid("cursor must be a cursor") end
            request.cursor = cursor
        end
        local value, failure = invoke(M.SESSIONS, "list", request, nil)
        if failure then return nil, failure end
        local page, decode_error = protocol.decode_list_page(value)
        if not page then return nil, unreadable(decode_error, nil) end
        return page, nil
    end

    client.catalog = function(_: Client, options: CatalogOptions?): (protocol.CatalogPage?, Fault?)
        local request: {[string]: unknown} = {}
        if options and options.kind ~= nil then
            if options.kind ~= "definition" and options.kind ~= "profile" then
                return nil, invalid("kind must be definition or profile")
            end
            request.kind = options.kind
        end
        if options and options.include_unavailable ~= nil then
            if type(options.include_unavailable) ~= "boolean" then return nil, invalid("include_unavailable must be a boolean") end
            request.include_unavailable = options.include_unavailable
        end
        if options and options.cursor ~= nil then
            local cursor = protocol.cursor(options.cursor)
            if not cursor then return nil, invalid("cursor must be a cursor") end
            request.cursor = cursor
        end
        local value, failure = invoke(M.CATALOG, "list", request, nil)
        if failure then return nil, failure end
        local page, decode_error = protocol.decode_catalog_page(value)
        if not page then return nil, unreadable(decode_error, nil) end
        return page, nil
    end

    return client
end

function M.client(): Client return new_client() end
local ambient_client = new_client()

function M.open(options: OpenOptions): (Session?, Fault?) return ambient_client:open(options) end
function M.call(options: CallOptions): (Call?, Fault?) return ambient_client:call(options) end
function M.send(options: SendOptions): (Work?, Fault?) return ambient_client:send(options) end
function M.cancel(options: CancelOptions): (Operation?, Fault?) return ambient_client:cancel(options) end
function M.close(options: CloseOptions): (Operation?, Fault?) return ambient_client:close(options) end
function M.await(options: ClientAwaitOptions): (AnyAwait?, Fault?) return ambient_client:await(options) end
function M.join(options: JoinOptions): (JoinAwait?, Fault?) return ambient_client:join(options) end
function M.get(ref: string): (Session?, Fault?) return ambient_client:get(ref) end
function M.work(ref: string): (Work?, Fault?) return ambient_client:work(ref) end
function M.list(options: ListOptions?): (protocol.ListPage?, Fault?) return ambient_client:list(options) end
function M.catalog(options: CatalogOptions?): (protocol.CatalogPage?, Fault?) return ambient_client:catalog(options) end

return M
