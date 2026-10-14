-- MIT. Create the application aliases that let an app family keep its threads.
local STATEMENTS = {
    [[CREATE TABLE bee_thread_app_alias (
  stable TEXT NOT NULL CHECK(length(CAST(stable AS BLOB)) <= 160),
  instance TEXT NOT NULL CHECK(length(CAST(instance AS BLOB)) <= 160),
  workspace_id TEXT NOT NULL
    CHECK(length(workspace_id) = 32 AND workspace_id NOT GLOB '*[^0-9a-f]*'),
  definition_id TEXT NOT NULL CHECK(length(CAST(definition_id AS BLOB)) <= 160),
  created_at TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 0 CHECK(active IN (0, 1)),
  PRIMARY KEY(stable, instance)
)]],
    [[CREATE INDEX bee_thread_app_alias_instance
  ON bee_thread_app_alias(instance, stable)]],
}

return require("migration").define(function()
    migration("Create the application aliases that let an app family keep its threads", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs({"bee_thread_app_alias"}) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
