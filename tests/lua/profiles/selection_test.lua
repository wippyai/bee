-- MIT. Saved-profile selection uses the Sessions catalog identity and revision,
-- never profile contents or a second launch-definition listing.
local test = require("test")
local agents = require("agents")
local sessions = require("sessions")

type Object = {[string]: unknown}
local PROFILE_ID = "saved-profile-selection-fixture"
local DEFINITION = "bee.driver.claude:default_window"

local function client_of(value: unknown): sessions.Client return value :: sessions.Client end

local function define_tests()
    test.describe("Saved profile Sessions catalog selection", function()
        test.it("opens the selected profile by its catalog revision without exposing its values", function()
            local opened: Object = {}
            local candidate: Object = {ref = PROFILE_ID, kind = "profile", revision = 4, title = "Personal Claude",
                status = "ready", checked_at = "2026-09-29T12:00:00.000Z", reasons = {}, features = {"driver:claude", "presentation:start_menu"},
                actions = {{operation = "session_open", label = "Open session"}}}
            local raw_client: any = {
                catalog = function(_: any, options: Object): (unknown, nil)
                    test.eq(options.include_unavailable, true)
                    return {items = {candidate}, complete = true, unavailable_count = 1, diagnostics = {}}, nil
                end,
                open = function(_: any, options: Object): (any, nil)
                    opened = options
                    return {snapshot = {title = "Personal Claude", lifecycle = "active", activity = "idle", queue_count = 0}}, nil
                end,
            }

            local client = client_of(raw_client)
            local listing, list_error = agents.list(client, false)
            if not listing then error(tostring(list_error)) end
            test.eq(#listing.items, 1)
            test.eq(listing.items[1].ref, PROFILE_ID)
            test.eq(listing.items[1].revision, 4)
            test.eq(listing.items[1].title, "Personal Claude")
            test.is_true(listing.items[1].ready)
            test.is_nil((listing.items[1] :: Object).options)
            test.is_nil((listing.items[1] :: Object).instructions)

            local conversation, open_error = agents.open(client, DEFINITION, {id = listing.items[1].ref,
                revision = listing.items[1].revision or 0}, "open-key")
            if not conversation then error(tostring(open_error)) end
            test.eq(opened.definition, DEFINITION)
            test.eq((opened.profile :: Object).id, PROFILE_ID)
            test.eq((opened.profile :: Object).revision, 4)
            test.eq(opened.operation_key, "open-key")
        end)
    end)
end

return test.run_cases(define_tests)
