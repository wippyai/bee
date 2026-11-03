local writable_roots = require("writable_roots")

type Object = {[string]: unknown}
type SecretField = {path: {string}, environment: string, prefix: string}
type JsonOperation = {kind: "default" | "insert" | "append" | "set", path: {string}}
type Composition = {kind: "copy", base_path: string} | {kind: "toml_insert", base_path: string, path: {string}, append_text: boolean?} | {kind: "json_patch" | "toml_patch", base_path: string, operations: {JsonOperation}}
type Configuration = {secret_fields: {SecretField}?, composition: Composition?, revision: string, path: string, content: string, digest: string, provider_ref: string}
type InstructionBuilder = {func_id: string, args: {[string]: unknown}}
type GatewayInput = {endpoint: string, action_id: string, tools: {string}, hooks: {string}, token_environment: string, hook_token_environment: string?, hook_command: string?}
type Delivery = {environment: {[string]: string}?,arguments: {string}, files: {Configuration}, git_writable_roots: writable_roots.Declaration?}
-- descriptor: the CLI descriptor declaration the driver binding names, which
-- the host reads for a configure method that runs without registry authority.
type Request = {placement: Object?, option_provenance: Object?, configure_renderer: string?, descriptor: Object?, option_values: Object?, context: string?,instructions_path: string?, instructions: string?, instruction_builder: InstructionBuilder?, provider_ref: string?, provider: Object?, gateway: GatewayInput?, home_directory: string?, private_home: boolean?, attempt_id: string?, fixture: boolean}

return {}
