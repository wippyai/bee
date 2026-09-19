# "Hash Functions"

_Path: en/lua/security/hash_

> "Cryptographic hash functions and HMAC message authentication."

## Table of Contents

- Hash Functions

## Content

# Hash Functions

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>
<secondary-label ref="encoding"/>

The `hash` module computes cryptographic hashes, HMAC values, PBKDF2-derived keys, and non-cryptographic FNV-1 hashes. This page is an API reference of isolated calls. Literal inputs illustrate successful use; when data, secrets, passwords, or salts come from the application, capture and handle the documented second `error` return before consuming the result.

A hash is not encryption and does not conceal low-entropy input. Do not log passwords, HMAC keys, derived keys, or raw secret-dependent digests. Use HMAC-SHA256 or HMAC-SHA512 for new message-authentication designs and PBKDF2 with a unique random salt for password verifiers.



## Loading


```lua
local hash = require("hash")
```



### MD5


MD5 is not collision-resistant. Use it only for compatibility with protocols that require MD5, not for security decisions.

```lua
local hex = hash.md5("data")
local raw = hash.md5("data", true)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Data to hash |
| `raw` | boolean? | Return raw bytes instead of hex |

**Returns:** `string, error`



### SHA-1


SHA-1 is not collision-resistant. Use it only for compatibility with protocols that require SHA-1, not for security decisions.

```lua
local hex = hash.sha1("data")
local raw = hash.sha1("data", true)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Data to hash |
| `raw` | boolean? | Return raw bytes instead of hex |

**Returns:** `string, error`



### SHA-256


```lua
local hex = hash.sha256("data")
local raw = hash.sha256("data", true)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Data to hash |
| `raw` | boolean? | Return raw bytes instead of hex |

**Returns:** `string, error`



### SHA-512


```lua
local hex = hash.sha512("data")
local raw = hash.sha512("data", true)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Data to hash |
| `raw` | boolean? | Return raw bytes instead of hex |

**Returns:** `string, error`



### HMAC-MD5


Use HMAC-MD5 only for compatibility with a protocol that requires it; prefer HMAC-SHA256 or HMAC-SHA512 for new designs.

```lua
local hex = hash.hmac_md5("message", "secret")
local raw = hash.hmac_md5("message", "secret", true)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Message to authenticate |
| `secret` | string | Secret key |
| `raw` | boolean? | Return raw bytes instead of hex |

**Returns:** `string, error`



### HMAC-SHA1


Use HMAC-SHA1 only for compatibility with a protocol that requires it; prefer HMAC-SHA256 or HMAC-SHA512 for new designs.

```lua
local hex = hash.hmac_sha1("message", "secret")
local raw = hash.hmac_sha1("message", "secret", true)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Message to authenticate |
| `secret` | string | Secret key |
| `raw` | boolean? | Return raw bytes instead of hex |

**Returns:** `string, error`



### HMAC-SHA256


```lua
local hex = hash.hmac_sha256("message", "secret")
local raw = hash.hmac_sha256("message", "secret", true)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Message to authenticate |
| `secret` | string | Secret key |
| `raw` | boolean? | Return raw bytes instead of hex |

**Returns:** `string, error`



### HMAC-SHA512


```lua
local hex = hash.hmac_sha512("message", "secret")
local raw = hash.hmac_sha512("message", "secret", true)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Message to authenticate |
| `secret` | string | Secret key |
| `raw` | boolean? | Return raw bytes instead of hex |

**Returns:** `string, error`



### FNV-1 32-bit


Compute a hash for uses such as hash tables and partitioning.

```lua
local n = hash.fnv32("data")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Data to hash |

**Returns:** `number, error`



### FNV-1 64-bit


Compute a wider hash for uses such as hash tables and partitioning, reducing collision probability.

```lua
local n = hash.fnv64("data")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Data to hash |

**Returns:** `number, error`



### PBKDF2


```lua
local key, err = hash.pbkdf2(password, salt, iterations, key_length)
local key, err = hash.pbkdf2(password, salt, iterations, key_length, "sha512")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `password` | string | Password/passphrase (non-empty) |
| `salt` | string | Salt value (non-empty) |
| `iterations` | integer | Iteration count (1 to 10,000,000) |
| `key_length` | integer | Desired key length in bytes |
| `hash` | string? | `sha256` or `sha512` (default: `sha256`) |

**Returns:** `string, error` (raw key bytes)



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Input not a string | `errors.INVALID` | no |
| Secret not a string (HMAC) | `errors.INVALID` | no |
| Empty password/salt, non-positive or excessive iterations, unsupported hash (PBKDF2) | `errors.INVALID` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Encryption & Signing" (lua/security/crypto)
Next: "UUID Generation" (lua/security/uuid)
