# "Entry Listeners and Observers"

_Path: en/internals/kinds_

> "How listeners and observers handle registry mutations for matching entry-kind patterns."

## Table of Contents

- Entry Listeners and Observers

## Content

# Entry Listeners and Observers


Entry listeners and observers process registry mutations for matching entry-kind patterns.

This is a Go extension reference. The registration and configuration snippets assume an existing boot component, manager, transcoder, and application config type.



## How It Works


Boot collects listeners and observers with their kind patterns. When an entry changes:

1. Registry emits event (`entry.create`, `entry.update`, `entry.delete`)
2. Each listener wrapper matches the entry kind against its registered pattern
3. Matching handlers receive the entry
4. Handlers process or reject the entry



## Kind Patterns


Handlers subscribe using patterns:

| Pattern | Matches |
|---------|---------|
| `http.service` | Exact match only |
| `http.*` | `http.service`, `http.router`, `http.endpoint` |
| `function.**` | `function.lua`, `function.lua.bc` |



## Entry Listener Interface


Handlers implement `registry.EntryListener`:

```go
type EntryListener interface {
    Add(ctx context.Context, entry Entry) error
    Update(ctx context.Context, entry Entry) error
    Delete(ctx context.Context, entry Entry) error
}
```

Returning an error from `Add`, `Update`, or `Delete` rejects that operation.



## Listener vs Observer


| Type | Purpose | Can Reject |
|------|---------|------------|
| Listener | Primary handler | Yes |
| Observer | Secondary handler (logging, metrics) | No |

```go
handlers.RegisterListener("http.*", httpManager)
handlers.RegisterObserver("function.*", metricsCollector)
```

Observer errors from `Add`, `Update`, and `Delete` are ignored and do not emit an accept or reject event. A listener or observer that also implements `TransactionListener` participates in transaction barriers, where an error from `Begin`, `Commit`, or `Discard` rejects that transaction phase.



## Registering Handlers


Register handlers during boot:

```go
func MyService() boot.Component {
    return boot.New(boot.P{
        Name:      "myservice",
        DependsOn: []boot.Name{core.RegistryName},
        Load: func(ctx context.Context) (context.Context, error) {
            handlers := bootpkg.GetHandlerRegistry(ctx)
            handlers.RegisterListener("myservice.*", manager)
            return ctx, nil
        },
    })
}
```



## Decoding Entry Data


Use `entry.DecodeEntryConfig` from `system/entry` to unmarshal entry data. `DecodeEntryConfigFromContext` takes the transcoder from the context instead of an argument, and `DecodeEntryConfigRaw` skips placeholder resolution:

```go
func (m *Manager) Add(ctx context.Context, ent registry.Entry) error {
    cfg, err := entry.DecodeEntryConfig[ComponentConfig](ctx, m.dtt, ent)
    if err != nil {
        return err
    }
    // Process cfg...
    return nil
}
```

The decoder:
1. Resolves `${env:...}` placeholders and `*_env` companion fields against the environment registry
2. Unmarshals `entry.Data` into your config struct
3. Populates `ID` and `Meta` from the entry when the struct leaves them empty
4. Calls `InitDefaults()` if implemented
5. Calls `Validate()` if implemented



## Config Structure


Entry configs typically include:

```go
type ComponentConfig struct {
    ID      registry.ID `json:"id"`
    Meta    attrs.Bag   `json:"meta"`
    Name    string      `json:"name"`
    Timeout int         `json:"timeout,omitempty"`
}

func (c *ComponentConfig) InitDefaults() {
    if c.Timeout == 0 {
        c.Timeout = 30
    }
}

func (c *ComponentConfig) Validate() error {
    if c.Name == "" {
        return fmt.Errorf("name is required")
    }
    return nil
}
```



## Transaction Support


For atomic operations across multiple entries, implement `TransactionListener`:

```go
type TransactionListener interface {
    Begin(ctx context.Context) error
    Commit(ctx context.Context) error
    Discard(ctx context.Context) error
}
```

The registry calls `Begin` before processing a batch, then `Commit` on success or `Discard` on failure.



## See Also


- [Registry](internals/registry.md) - Entry storage
- [Architecture](internals/architecture.md) - Boot sequence



## Navigation

Previous: "Lua Modules" (internals/modules)
Next: "Contributing" (about/contributing)
