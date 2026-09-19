# "Why Wippy Uses Lua"

_Path: en/lua/why-lua_

> "The runtime constraints, tradeoffs, and complementary roles of Lua and WebAssembly in Wippy."

## Table of Contents

- Why Wippy Uses Lua

## Content

# Why Wippy Uses Lua


Wippy uses Lua as its primary runtime language because it fits the platform's process-isolation and embedding requirements. This page explains that design choice and its tradeoffs; it is not a general ranking of programming languages.

This is a conceptual design note rather than a runnable tutorial. It describes runtime properties and points to the reference pages that define the concrete APIs.



## Runtime Requirements


Wippy runs user-defined logic in isolated processes. Each process has its own memory and receives only the capabilities exposed by the runtime. Because many processes can run concurrently, the embedded language must support:

- **Low per-process overhead.** Memory use must remain practical as process counts grow.
- **Capability isolation.** The runtime must control the modules, functions, and system operations available to each process.
- **In-process embedding.** Wippy's Go core must be able to create, configure, and stop a language environment for each process.
- **Controlled module loading.** Modules must come from the runtime's allowlist or declared registry imports rather than arbitrary file-system paths.
- **A small language surface.** Application code should remain readable and straightforward to generate, review, and lint.



### Python


Python offers a large application and data ecosystem, but its interpreter, import model, and package assumptions do not match Wippy's per-process embedding and capability model. Python services can still integrate with Wippy over explicit service boundaries.



### JavaScript


JavaScript runtimes offer several embedding options. Their module and package ecosystems, however, require a separate integration layer to provide the registry-scoped loading model Wippy uses. Wippy chose Lua's smaller host-controlled runtime surface for application code.



### Go


Go is used for Wippy's core runtime. Compiled Go code and plugins do not provide the same isolated, per-process embedded environment required for user-defined application logic.



### WebAssembly


WebAssembly fills a complementary role rather than replacing Lua as the primary authoring language. Its division of responsibilities is described in [Lua and WebAssembly](#lua-and-webassembly).



### Host-Controlled Embedding


Lua is designed to run inside a host application. Wippy creates an environment for each process, connects it to the scheduler and registry, and controls its globals and module loader. `require` reads only modules already installed in that environment: the always-available base modules and standard libraries, the executable entry's ambient `process` module, built-in runtime modules allowed by `modules:`, and registry libraries declared through `imports:`. It does not search file-system paths or install packages from the network. Different entries can therefore receive different module sets without application-level loading rules.



### Language Surface


Lua has a compact syntax and a small standard environment. Wippy adds type annotations and linting so code can be checked incrementally without changing the underlying execution model.



### Cooperative Scheduling


Lua coroutines map to Wippy's cooperative scheduling model. A process can yield during channel or I/O operations while the scheduler runs other work.



## Tradeoffs


Lua does not provide an in-process package ecosystem comparable to pip or npm. Wippy supplies built-in runtime modules through an allowlist and application libraries through registry imports rather than installing packages from the network. Workloads that depend on large external libraries can run as services or as WebAssembly components.

Lua may also be unfamiliar to developers coming from other languages. The syntax is compact, but teams still need conventions, review, and linting for production code.



## Lua and WebAssembly


Wippy provides two complementary runtimes:

- **Lua** is the primary runtime for application logic, tools, and agents.
- **WebAssembly** runs compiled workloads and existing code that can target WASM.

Lua and WASM process entries use Wippy's process model; Lua and WASM functions are exposed through registered function entries. Both integrations are configured through the registry and runtime security policies. Lua code can call registered WASM functions, and WASM processes can call registered Lua functions.



## See Also


- [Lua Runtime Overview](lua/overview.md) - The Lua runtime and its modules
- [Types](lua/types.md) - Type annotations, generics, and unions
- [Linter](guides/linter.md) - Static analysis for Lua
- [WASM Runtime](wasm/overview.md) - Running compiled code in the sandbox



## Navigation

Previous: "Lua Runtime" (lua/overview)
Next: "Type System" (lua/types)
