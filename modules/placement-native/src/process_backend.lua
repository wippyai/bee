-- SPDX-License-Identifier: MIT
local exec = require("exec")
local sql = require("sql")
local types = require("types")
local materialization = require("materialization")
type Mount = {source: string, target: string, read_only?: boolean}
type Options = {work_dir?: string, env?: {[string]: string}, process_group?: boolean, stdin_materialized?: boolean, pty?: {width?: integer, height?: integer, term?: string}, mounts?: {{source: string, target: string, read_only?: boolean}}}
type Backend = {
    guest_home: string,
    binding: string,
    prepare: (sql.DB, types.LaunchRequest, materialization.Prepared) -> (exec.Executor?, {string}?, Options?, string?),
    identity: (types.LaunchRequest) -> ({[string]: unknown}?, string?),
    cleanup: (types.Attempt, boolean?) -> (boolean, string?),
    absent: (types.LaunchRequest) -> (boolean, string?),
    stop: ((types.Attempt) -> (boolean, string?))?,
}
return {}
