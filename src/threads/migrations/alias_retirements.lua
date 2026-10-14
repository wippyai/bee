-- SPDX-License-Identifier: MIT
return require("migration").define(function()
    migration("Persist application alias retirement intent", function()
        database("sqlite", function()
            up(function(db)
                assert(db:execute("ALTER TABLE bee_thread_app_alias ADD COLUMN generation INTEGER NOT NULL DEFAULT 1 CHECK(generation > 0)"))
                assert(db:execute([[CREATE TABLE bee_thread_app_alias_retirements (
                    stable TEXT NOT NULL, instance TEXT NOT NULL, generation INTEGER NOT NULL,
                    PRIMARY KEY(stable, instance, generation),
                    FOREIGN KEY(stable, instance) REFERENCES bee_thread_app_alias(stable, instance)
                )]]))
            end)
            down(function(db)
                assert(db:execute("DROP TABLE bee_thread_app_alias_retirements"))
                assert(db:execute("ALTER TABLE bee_thread_app_alias DROP COLUMN generation"))
            end)
        end)
    end)
end)
