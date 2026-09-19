# "Encryption & Signing"

_Path: en/lua/security/crypto_

> "Cryptographic operations including encryption, HMAC, JWT, and key derivation. Adapted for workflows."

## Table of Contents

- Encryption & Signing

## Content

# Encryption & Signing

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>
<secondary-label ref="io"/>

The `crypto` module generates random values, computes HMACs, encrypts and decrypts data, encodes and verifies JWTs, and derives keys. In deterministic workflows, random generation and encryption (which creates a random nonce) run as recorded side effects; replay returns the recorded bytes. Other operations, including HMAC, decryption, JWT processing, PBKDF2, and comparison, run directly.

This page is an API reference. Each code block is an isolated call, not a complete key-management or authentication system. Names such as `data`, `key`, `aad`, `payload`, and `token` are application-provided values. Load keys and passwords through the application's secret-management boundary; do not hard-code, log, or return them in diagnostics. Before consuming any `value, error` result shown here, propagate or handle the error.



## Loading


```lua
local crypto = require("crypto")
```



### Random Bytes


```lua
local bytes, err = crypto.random.bytes(32)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `length` | integer | Number of bytes (1 to 1,048,576) |

**Returns:** `string, error`



### Random String


```lua
local str, err = crypto.random.string(32)
local str, err = crypto.random.string(32, "0123456789abcdef")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `length` | integer | Output length in bytes (1 to 1,048,576) |
| `charset` | string? | ASCII byte alphabet to use (default: alphanumeric) |

**Returns:** `string, error`

The implementation selects bytes from the supplied alphabet. A non-ASCII alphabet can be split into invalid UTF-8, and modulo selection is exactly uniform only when the alphabet's byte length divides 256. For uniformly random secret material, use `crypto.random.bytes` and encode the result for the required transport format.



### Random UUID


```lua
local id, err = crypto.random.uuid()
```

**Returns:** `string, error`



### HMAC-SHA256


```lua
local hex, err = crypto.hmac.sha256(key, data)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | HMAC key |
| `data` | string | Data to authenticate |

**Returns:** `string, error`



### HMAC-SHA512


```lua
local hex, err = crypto.hmac.sha512(key, data)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | HMAC key |
| `data` | string | Data to authenticate |

**Returns:** `string, error`



### AES-GCM {id="encrypt-aes-gcm"}


```lua
local encrypted, err = crypto.encrypt.aes(data, key)
local encrypted, err = crypto.encrypt.aes(data, key, aad)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Plaintext to encrypt |
| `key` | string | 16, 24, or 32 bytes (AES-128/192/256) |
| `aad` | string? | Additional authenticated data |

**Returns:** `string, error` (nonce prepended)

Both encryption functions generate a nonce and prepend it to the ciphertext. Do not remove or reuse it, and use the same AAD during decryption. Ciphertext is not a secret-free log value: it can expose length and correlation information.



### ChaCha20-Poly1305 {id="encrypt-chacha20"}


```lua
local encrypted, err = crypto.encrypt.chacha20(data, key)
local encrypted, err = crypto.encrypt.chacha20(data, key, aad)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Plaintext to encrypt |
| `key` | string | Must be 32 bytes |
| `aad` | string? | Additional authenticated data |

**Returns:** `string, error` (nonce prepended)



### AES-GCM {id="decrypt-aes-gcm"}


```lua
local plaintext, err = crypto.decrypt.aes(encrypted, key)
local plaintext, err = crypto.decrypt.aes(encrypted, key, aad)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Encrypted data from encrypt.aes |
| `key` | string | Same key used for encryption |
| `aad` | string? | Must match AAD used in encryption |

**Returns:** `string, error`



### ChaCha20-Poly1305 {id="decrypt-chacha20"}


```lua
local plaintext, err = crypto.decrypt.chacha20(encrypted, key)
local plaintext, err = crypto.decrypt.chacha20(encrypted, key, aad)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Encrypted data from encrypt.chacha20 |
| `key` | string | Same key used for encryption |
| `aad` | string? | Must match AAD used in encryption |

**Returns:** `string, error`



### Encode


```lua
local token, err = crypto.jwt.encode(payload, secret)
local token, err = crypto.jwt.encode(payload, secret, "HS256")
local token, err = crypto.jwt.encode(payload, private_key_pem, "RS256")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `payload` | table | JWT claims (`_header` for custom header) |
| `key` | string | Secret (HMAC) or PEM private key (RSA) |
| `alg` | string? | HS256, HS384, HS512, RS256 (default: HS256) |

**Returns:** `string, error`

Pass only one of the documented algorithm names. At this runtime pin, an unsupported value passed to `encode` falls back to HS256 instead of returning an error. Validate any configurable algorithm before this call, and do not copy untrusted fields into `_header`; in particular, do not let input override reserved JWT headers such as `alg`.



### Verify


```lua
local claims, err = crypto.jwt.verify(token, secret)
local claims, err = crypto.jwt.verify(token, secret, "HS256", false)
local claims, err = crypto.jwt.verify(token, public_key_pem, "RS256")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | JWT token to verify |
| `key` | string | Secret (HMAC) or PEM public key (RSA) |
| `alg` | string? | Expected algorithm (default: HS256) |
| `require_exp` | boolean? | Require an `exp` claim to be present (default: true); an `exp` that is present is always validated |

**Returns:** `table, error`

Whenever present, `exp` and `nbf` are validated against the JWT library's current wall clock, not the workflow time reference. Setting `require_exp = false` permits a missing `exp` claim; it does not disable validation of a claim that is present. Do not use either time-dependent result for replay-sensitive workflow control; perform the check in an activity or validate time against an explicitly replay-safe value.

Always pass the algorithm expected by the issuer; verification restricts the token to that exact method. Treat returned claims as authenticated data, not automatically authorized application input, and still validate issuer, audience, subject, and application-specific constraints.



### PBKDF2


```lua
local key, err = crypto.pbkdf2(password, salt, iterations, key_length)
local key, err = crypto.pbkdf2(password, salt, iterations, key_length, "sha512")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `password` | string | Password/passphrase |
| `salt` | string | Salt value |
| `iterations` | integer | Iteration count (max 10,000,000) |
| `key_length` | integer | Desired key length in bytes |
| `hash` | string? | sha256 or sha512 (default: sha256) |

**Returns:** `string, error`

The derived key is raw bytes. Use a fresh random salt for each stored password verifier and store the salt and work-factor parameters alongside the verifier; the salt need not be secret. Do not use a fixed example salt for production password storage.



### Constant-Time Compare


```lua
local equal = crypto.constant_time_compare(a, b)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `a` | string | First string |
| `b` | string | Second string |

**Returns:** `boolean`

The result is `false` when lengths differ. The underlying constant-time comparison guarantee applies to equal-length inputs, so compare fixed-length digests or other same-length secrets.



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Invalid length | `errors.INVALID` | no |
| Empty key | `errors.INVALID` | no |
| Invalid key size | `errors.INVALID` | no |
| Decryption failed | `errors.INTERNAL` | no |
| Token expired | `errors.INTERNAL` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Security & Access Control" (lua/security/security)
Next: "Hash Functions" (lua/security/hash)
