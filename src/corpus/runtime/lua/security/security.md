# "Security & Access Control"

_Path: en/lua/security/security_

> "Manage authentication actors, authorization scopes, and access policies."

## Table of Contents

- Security & Access Control

## Content

# Security & Access Control

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="permissions"/>

The `security` module exposes authentication actors, authorization scopes, policies, and token stores. This page is an API reference with partial authorization recipes. Registry IDs, actors, request metadata, token values, application objects such as `user` and `doc`, and callbacks such as `show_admin_features` come from the surrounding application; the examples are not a complete authentication deployment.

Wippy runs in strict security mode by default. The executable entry must enable `security`, have an actor and scope, and authorize the exact operations it calls. In particular, construction and scope changes need `security.actor.create` or `security.scope.create`; registry lookup needs `security.policy.get` or `security.policy_group.get`; token work needs `security.token_store.get` plus the operation-specific token permission. `new_actor`, `new_scope`, `scope:with`, `scope:without`, and permission-denied `token_store` acquisition raise a Lua error instead of returning a structured `error`. Grant these prerequisites in the entry's security context rather than trying to recover after a denial. See [Security Model](system/security.md) for configuration.



## Loading


```lua
local security = require("security")
```



## `actor`


Return the current security actor from the execution context.

```lua
local actor = security.actor()
if actor then
    local id = actor:id()
    local meta = actor:meta()
    -- Use only the fields required for authorization or application logic.
    local role = meta.role
end
```

Actor metadata can contain identifiers or personal data. Do not log the complete metadata table or copy secrets into it.

**Returns:** `Actor|nil`



## `scope`


Return the current security scope from the execution context.

```lua
local scope = security.scope()
if scope then
    local policies = scope:policies()
    for _, policy in ipairs(policies) do
        print("Active policy:", policy:id())
    end
end
```

**Returns:** `Scope|nil`



## `can`


Check whether the current context allows an action on a resource.

```lua
-- Check read permission
if not security.can("read", "user:" .. user_id) then
    return nil, errors.new("Cannot read user data"):kind(errors.PERMISSION_DENIED)
end

-- Check write permission
if not security.can("write", "order:" .. order_id) then
    return nil, errors.new("Cannot modify order"):kind(errors.PERMISSION_DENIED)
end

-- Check with metadata
local allowed = security.can("delete", "document:" .. doc_id, {
    owner_id = doc.owner_id,
    department = doc.department
})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `action` | string | Action to check |
| `resource` | string | Resource identifier |
| `meta` | table | Additional metadata (optional) |

**Returns:** `boolean`



## `new_actor`


Create an actor with an ID and metadata.

```lua
-- Create user actor
local actor = security.new_actor("user:" .. user.id, {
    role = user.role,
    department = user.department,
    email = user.email
})

-- Create service actor
local service_actor = security.new_actor("service:payment-processor", {
    type = "service",
    version = "1.0.0"
})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Unique actor identifier |
| `meta` | table | Metadata key-value pairs |

**Returns:** `Actor`



## `new_scope`


Create a custom scope.

```lua
-- Empty scope
local scope = security.new_scope()

-- Scope with policies
local read_policy, read_err = security.policy("app:read-only")
if read_err then
    return nil, read_err
end
local scope = security.new_scope({read_policy})

-- Build scope incrementally
local scope = security.new_scope()
local policy1, policy1_err = security.policy("app:read")
if policy1_err then
    return nil, policy1_err
end
local policy2, policy2_err = security.policy("app:write")
if policy2_err then
    return nil, policy2_err
end
scope = scope:with(policy1):with(policy2)
```

Each alternative above is an isolated construction pattern. `new_scope` and `scope:with` can raise on missing context or permission denial; they do not return `nil, error` for those checks.

**Returns:** `Scope`



## `policy`


Retrieve a policy from the registry.

```lua
local policy, err = security.policy("app:admin-access")
if err then
    return nil, err
end

-- Evaluate policy
local result = policy:evaluate(actor, "delete", "user:123")
if result == "allow" then
    -- permitted
elseif result == "deny" then
    -- forbidden
else
    -- undefined, check other policies
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Policy ID "namespace:name" |

**Returns:** `Policy, error`



## `named_scope`


Retrieve a predefined policy group.

```lua
-- Get admin scope
local admin_scope, err = security.named_scope("app:admin")
if err then
    return nil, err
end

-- Use for elevated operations
local result = admin_scope:evaluate(actor, "delete", "user:123")
```

Loading a scope does not elevate the current execution context. It produces a value for explicit evaluation or for an API that accepts a scope; the caller still needs permission to perform the protected operation.

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Policy group ID |

**Returns:** `Scope, error`



## `token_store`


Acquire a token store for managing authentication tokens.

```lua
local store, err = security.token_store("app:tokens")
if err then
    return nil, err
end

-- Use store...
return store:close()
```

The caller owns an acquired token store until `close()` is called. Close it after the final operation on every checked success or error path; repeated closes are safe. A permission denial during acquisition raises a Lua error, while lookup and resource failures return `nil, error`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Token store ID "namespace:name" |

**Returns:** `TokenStore, error`



## `Actor` Methods


| Method | Returns | Description |
|--------|---------|-------------|
| `actor:id()` | string | Actor identifier |
| `actor:meta()` | table | Actor metadata |



### `with` / `without`


Add or remove policies from scope.

```lua
local scope = security.new_scope()

-- Add policy
local write_policy, err = security.policy("app:write")
if err then
    return nil, err
end
scope = scope:with(write_policy)

-- Remove policy
scope = scope:without("app:read-only")
```

`with` and `without` return new immutable scope values and raise when `security.scope.create` is not allowed for the `with` or `without` resource.



### `evaluate`


Evaluate all policies in scope.

```lua
local result = scope:evaluate(actor, "read", "document:123")
-- "allow", "deny", or "undefined"

if result ~= "allow" then
    return nil, errors.new("Access denied"):kind(errors.PERMISSION_DENIED)
end
```



### `contains`


Check whether the scope contains a policy.

```lua
if scope:contains("app:admin") then
    show_admin_features()
end
```



### `policies`


Return all policies in the scope.

```lua
local policies = scope:policies()
for _, policy in ipairs(policies) do
    print(policy:id())
end
```

**Returns:** `Policy[]`



## `Policy` Methods


| Method | Returns | Description |
|--------|---------|-------------|
| `policy:id()` | string | Policy identifier |
| `policy:evaluate(actor, action, resource, meta?)` | string | `"allow"`, `"deny"`, or `"undefined"` |



### `create`


Create an authentication token.

```lua
local actor = security.new_actor("user:123", {role = "user"})
local scope, scope_err = security.named_scope("app:default")
if scope_err then
    return nil, scope_err
end
local store, store_err = security.token_store("app:tokens")
if store_err then
    return nil, store_err
end

local token, err = store:create(actor, scope, {
    expiration = "24h",  -- or milliseconds
    meta = {
        login_ip = request_ip,
        user_agent = user_agent
    }
})
store:close()
if err then
    return nil, err
end
return token
```

`request_ip` and `user_agent` are application-provided request values. Store only metadata needed for security decisions, apply retention limits, and never log or persist the returned bearer token outside the intended credential store.

| Parameter | Type | Description |
|-----------|------|-------------|
| `actor` | Actor | Actor for the token |
| `scope` | Scope | Permissions scope |
| `options.expiration` | string/number | Duration string or ms |
| `options.meta` | table | Token metadata |

**Returns:** `string, error`



### `validate`


Validate a token and return its actor and scope.

```lua
local actor, scope, err = store:validate(token)
store:close()
if err then
    return nil, errors.new("Invalid token"):kind(errors.PERMISSION_DENIED)
end
```

Here and below, `store` is a live owned handle and `token` is an untrusted bearer credential supplied by the caller. Do not log the token, including on validation or revocation errors.

**Returns:** `Actor, Scope, error`



### `revoke`


Invalidate a token.

```lua
local ok, err = store:revoke(token)
store:close()
if err then
    return nil, err
end
```

**Returns:** `boolean, error`



### `close`


Release the token store resource.

```lua
store:close()
```

**Returns:** `boolean`



## Permissions


Security policy evaluation applies to security operations.



### Security Actions


| Action | Resource | Description |
|--------|----------|-------------|
| `security.policy.get` | Policy ID | Access policy definitions |
| `security.policy_group.get` | Group ID | Access named scopes |
| `security.scope.create` | `custom`, `with`, `without` | Create custom scopes (`new_scope`) and add/remove policies (`scope:with`, `scope:without`) |
| `security.actor.create` | Actor ID | Create actors |
| `security.token_store.get` | Store ID | Access token stores |
| `security.token.validate` | Store ID | Validate tokens |
| `security.token.create` | Store ID | Create tokens |
| `security.token.revoke` | Store ID | Revoke tokens |

See [Security Model](system/security.md) for policy configuration.



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| No context | `errors.INTERNAL` | no |
| Empty token store ID | `errors.INVALID` | no |
| Permission denied (`policy`, `named_scope`, token `create`/`validate`/`revoke`) | `errors.INVALID` | no |
| Permission denied (`new_scope`, `new_actor`, `token_store`, `scope:with`/`without`) | raised as a Lua error | no |
| Policy not found | `errors.INTERNAL` | no |
| Token store not found | `errors.INTERNAL` | no |
| Token store closed | `errors.INTERNAL` | no |
| Invalid expiration format | `errors.INVALID` | no |
| Token validation failed | `errors.INTERNAL` | no |

```lua
local store, err = security.token_store("app:tokens")
if err then
    if errors.is(err, errors.INVALID) then
        print("Invalid request:", err:message())
    end
    return nil, err
end
store:close()
```

See [Error Handling](lua/core/errors.md) for working with errors.



## See Also


- [Security Model](../../system/security.md) - Actors, policies, scopes configuration
- [HTTP Middleware](http/middleware.md) - Endpoint and resource firewall



## Navigation

Previous: "Tree-sitter Parsing" (lua/text/treesitter)
Next: "Encryption & Signing" (lua/security/crypto)
