-- MIT. Measurements of host executable files, each keyed by what was measured
-- and recorded with the identity of the file version it was taken from.
return require("migration").define(function()
    migration("Create executable measurements", function()
        database("sqlite", function()
            up(function(db)
                assert(db:execute([[CREATE TABLE bee_placement_executable_measurements (
                    key_digest TEXT PRIMARY KEY,
                    path TEXT NOT NULL,
                    dev TEXT,
                    ino TEXT,
                    size INTEGER NOT NULL CHECK (size >= 0),
                    ctime_ns TEXT,
                    mtime_ns TEXT NOT NULL,
                    measurement TEXT NOT NULL CHECK (length(CAST(measurement AS BLOB)) <= 524288),
                    measured_at TEXT NOT NULL)]]))
            end)
            down(function(db)
                assert(db:execute("DROP TABLE IF EXISTS bee_placement_executable_measurements"))
            end)
        end)
    end)
end)
