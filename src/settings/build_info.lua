-- SPDX-License-Identifier: MIT
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

function M.info(native: string?, native_version: string?, runtime_commit: string?): Info
    return {
        version = "development (unknown)",
        build = "development (unknown)",
        source = "development source (unknown)",
        source_revision = "development source (unknown)",
        runtime = "development runtime (unknown)",
        runtime_commit = runtime_commit or "development runtime (unknown)",
        native = native or "development native (unknown)",
        native_version = native_version or "development native (unknown)",
        website = "https://bee.wippy.ai",
    }
end

return M
