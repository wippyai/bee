-- MIT. The subscription session as the consumer holds it: pure transitions
-- over what the thread owner returned. The owner keeps cursor and page
-- acknowledgment authority; a transport reconnect acknowledges nothing and
-- advances nothing. Owner incarnation and lease generation fence stale
-- traffic: a reconnect either continues the same lease, must resume under
-- a new owner incarnation, or must reset because the subscription closed.
local M = {}
type Summary = {subscription_id: string, after_sequence: integer, lease_generation: integer, owner_incarnation: integer, owner_authority: string, closed: boolean}
type Page = {page_id: string, lease_generation: integer, from_sequence: integer, scanned_through: integer}
type State = "attached" | "detached" | "resume_required" | "reset_required" | "closed"
type Session = {subscription_id: string, owner_authority: string, owner_incarnation: integer, lease_generation: integer, after_sequence: integer, state: State, outstanding: Page?}
type Reconnect = "continue" | "resume" | "reset" | "stale"
-- The owner's generation order within one durable authority: incarnation
-- first, then lease generation. Numbers from another authority do not
-- compare at all.
local function compare(session: Session, summary: Summary): integer
    if summary.owner_incarnation ~= session.owner_incarnation then
        if summary.owner_incarnation > session.owner_incarnation then return 1 end
        return -1
    end
    if summary.lease_generation ~= session.lease_generation then
        if summary.lease_generation > session.lease_generation then return 1 end
        return -1
    end
    return 0
end
-- attach: the session a subscribe or resume reply establishes.
function M.attach(summary: Summary): Session
    local state: State = "attached"
    if summary.closed then state = "closed" end
    return {subscription_id = summary.subscription_id, owner_authority = summary.owner_authority, owner_incarnation = summary.owner_incarnation, lease_generation = summary.lease_generation,
        after_sequence = summary.after_sequence, state = state, outstanding = nil}
end
-- disconnect: transport loss changes nothing durable; the outstanding page
-- stays outstanding at the owner and the cursor stays where it was.
function M.disconnect(session: Session): Session
    if session.state == "attached" then session.state = "detached" end
    return session
end
-- reconnect: compared with the owner's current view of the subscription
-- under the owner's generation order. The same lease under the same
-- incarnation continues; a newer generation requires an explicit resume,
-- which fences every earlier page; a closed subscription requires a reset;
-- an older generation, or an equal one with a cursor behind the session's,
-- is a stale summary and changes nothing.
function M.reconnect(session: Session, current: Summary): (Session, Reconnect)
    if current.subscription_id ~= session.subscription_id or current.owner_authority ~= session.owner_authority then
        session.state = "reset_required"
        return session, "reset"
    end
    local order = compare(session, current)
    if order < 0 then return session, "stale" end
    if current.closed then
        session.state = "closed"
        return session, "reset"
    end
    if order > 0 then
        session.state = "resume_required"
        session.outstanding = nil
        return session, "resume"
    end
    if current.after_sequence < session.after_sequence then return session, "stale" end
    session.state = "attached"
    session.after_sequence = current.after_sequence
    return session, "continue"
end
-- resumed: the reply to resume_subscription installs the new lease, which
-- must be newer than the one the session holds; the cursor is the
-- owner's, never the consumer's memory of it.
function M.resumed(session: Session, summary: Summary): (Session, string?)
    if summary.subscription_id ~= session.subscription_id then return session, "summary names another subscription" end
    if summary.owner_authority ~= session.owner_authority then return session, "summary comes from another owner authority; reset" end
    if compare(session, summary) <= 0 then return session, "stale summary: not a newer lease" end
    session.owner_incarnation = summary.owner_incarnation
    session.lease_generation = summary.lease_generation
    session.after_sequence = summary.after_sequence
    session.outstanding = nil
    session.state = "attached"
    if summary.closed then session.state = "closed" end
    return session, nil
end
-- accept_page: a page counts only under the session's lease; anything
-- else is stale traffic from an earlier lease and is dropped.
function M.accept_page(session: Session, page: Page): (boolean, string?)
    if session.state ~= "attached" then return false, "session is " .. session.state end
    if page.lease_generation ~= session.lease_generation then return false, "page belongs to lease generation " .. tostring(page.lease_generation) .. ", not " .. tostring(session.lease_generation) end
    if session.outstanding and session.outstanding.page_id ~= page.page_id then return false, "page " .. session.outstanding.page_id .. " is still outstanding" end
    session.outstanding = page
    return true, nil
end
-- acknowledgment: what the consumer sends the owner; it names the page and
-- its exact extent, and only the owner's reply moves the cursor.
function M.acknowledgment(session: Session): ({page_id: string, scanned_through: integer}?, string?)
    if session.state ~= "attached" then return nil, "session is " .. session.state end
    local page = session.outstanding
    if not page then return nil, "no page is outstanding" end
    return {page_id = page.page_id, scanned_through = page.scanned_through}, nil
end
function M.acknowledged(session: Session, after_sequence: integer): Session
    session.after_sequence = after_sequence
    session.outstanding = nil
    return session
end
return M
