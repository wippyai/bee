-- MIT. Validate one operation reply against its advertised output schema and
-- byte ceiling. Generic to every forwarded operation; the caller still
-- decodes the owner's envelope.
local canonical = require("canonical")
local json = require("json")
local M = {}
function M.validate(output_schema: {[string]: unknown}, max_output_bytes: integer, output: unknown): (boolean, string?)
    if type(output) ~= "table" then return false, "output must be an object" end
    local schema_bytes, schema_error = canonical.encode(output_schema)
    if not schema_bytes then return false, "output schema encoding failed: " .. tostring(schema_error) end
    local valid, validation = json.validate(schema_bytes, output)
    if not valid then return false, "output does not satisfy schema: " .. tostring(validation) end
    local encoded, encode_error = canonical.encode(output)
    if not encoded then return false, "output encoding failed: " .. tostring(encode_error) end
    if #encoded > max_output_bytes then return false, "output exceeds maximum allowed bytes" end
    return true, nil
end
return M
