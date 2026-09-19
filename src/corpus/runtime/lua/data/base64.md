# "Base64 Encoding"

_Path: en/lua/data/base64_

> "Encode binary data to base64 strings and decode base64 back to binary. Uses standard base64 encoding per RFC 4648."

## Table of Contents

- Base64 Encoding

## Content

# Base64 Encoding

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>
<secondary-label ref="encoding"/>

The `base64` module encodes strings and binary data using standard RFC 4648 Base64 and decodes them back to bytes.

This is an API reference. Output-only expressions show successful values; filesystem and transport examples check the optional second `error` return before consuming data. Names such as `username`, `password`, `encoded_image`, and `user_input` are application-supplied strings.

Base64 is an encoding, not encryption or authentication. Do not use it to conceal secrets or to verify that data has not been modified. Send Basic authentication credentials only over TLS and obtain them from application-owned secret storage rather than literals.



## Loading


```lua
local base64 = require("base64")
```

Add `base64` to the executable entry's `modules:` list before requiring it. Filesystem and JSON examples also require `fs` and `json` respectively.



### `encode`


Encodes a string, including binary data, as Base64.

```lua
-- Encode text
local encoded, err = base64.encode("Hello, World!")
if err then return nil, err end
print(encoded)  -- "SGVsbG8sIFdvcmxkIQ=="

-- Encode binary data (e.g., from file)
local image_data = fs.get("app:data"):readfile("photo.jpg")
local image_b64 = base64.encode(image_data)

-- Encode JSON for transport
local json = require("json")
local payload, json_err = json.encode({user = "alice", action = "login"})
if json_err then return nil, json_err end
local token_part, token_err = base64.encode(payload)
if token_err then return nil, token_err end

-- Encode credentials
local credentials, credentials_err = base64.encode(username .. ":" .. password)
if credentials_err then return nil, credentials_err end
local auth_header = "Basic " .. credentials
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Data to encode (text or binary) |

**Returns:** `string, error` — an empty input returns an empty string



### `decode`


Decodes a Base64 string to its original bytes.

```lua
-- Decode text
local decoded, decode_err = base64.decode("SGVsbG8sIFdvcmxkIQ==")
if decode_err then return nil, decode_err end
print(decoded)  -- "Hello, World!"

-- Decode with error handling
local data, err = base64.decode(user_input)
if err then
    return nil, errors.new("Invalid base64 data"):kind(errors.INVALID)
end

-- Decode binary data
local image_data, err = base64.decode(encoded_image)
if err then
    return nil, err
end
fs.get("app:data"):writefile("output.jpg", image_data)

-- Decode a base64-wrapped JSON document
local json = require("json")
local doc = json.decode(base64.decode(encoded_json))
```

The final block demonstrates delimiter handling only. It does not parse or verify a signed token format.

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Base64-encoded string |

**Returns:** `string, error` — an empty input returns an empty string



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Input not a string | `errors.INVALID` | no |
| Invalid base64 characters | `errors.INVALID` | no |
| Corrupted padding | `errors.INVALID` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "YAML Encoding" (lua/data/yaml)
Next: "Compression" (lua/data/compress)
