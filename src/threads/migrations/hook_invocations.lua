local STATEMENTS = {
    [[CREATE TABLE bee_session_hook_invocations (invocation_id TEXT PRIMARY KEY, occurrence_key TEXT NOT NULL UNIQUE, session_ref TEXT NOT NULL, trait_id TEXT NOT NULL, selection_revision INTEGER NOT NULL, point TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','completed','diagnostic')), reply_json TEXT, diagnostic TEXT, FOREIGN KEY(session_ref,trait_id) REFERENCES bee_session_traits(session_ref,trait_id))]],
    [[CREATE TABLE bee_session_hook_originals (record_ref TEXT PRIMARY KEY, invocation_id TEXT NOT NULL UNIQUE, session_ref TEXT NOT NULL, trait_id TEXT NOT NULL, grant_id TEXT NOT NULL, original_json TEXT NOT NULL, FOREIGN KEY(invocation_id) REFERENCES bee_session_hook_invocations(invocation_id))]],
}
return require("migration").define(function()
    migration("Fence session hook invocations and retain consented originals", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
