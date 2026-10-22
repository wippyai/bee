type File = {kind: "file_exists", paths: {string}, variable: string?, directory: string?}
type Environment = {kind: "env_present", names: {string}}
type Status = {kind: "auth_status", argv: {string}, success_exit_code: integer, timeout_ms: integer}
type Evidence = File | Environment | Status
type Declaration = {command: string, any_of: {Evidence}}
type Check = {present: boolean?, exit_code: integer?, reason: string?}
type Probe = {file: (string, string?, string?) -> (boolean?, string?), environment: (string) -> boolean?,
    status: ({string}, integer) -> integer?}

return {}
