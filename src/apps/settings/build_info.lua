-- SPDX-License-Identifier: MIT
-- The bundle builder replaces this development fallback in staged source.
local M = {}
type Info = {
    version: string,
    build: string,
    source: string,
    source_revision: string,
    runtime: string,
    runtime_commit: string,
    native: string,
    native_version: string,
    website: string,
}

function M.info(): Info
    return {
        version = "development (unknown)",
        build = "development (unknown)",
        source = "development source (unknown)",
        source_revision = "development source (unknown)",
        runtime = "development runtime (unknown)",
        runtime_commit = "development runtime (unknown)",
        native = "development native (unknown)",
        native_version = "development native (unknown)",
        website = "https://bee.wippy.ai",
    }
end

return M
