# bee.application

The public application SDK. It provides bounded launch arguments, application
client and interaction values, caller and status helpers, semantic appearance
and naming values, and the wire decoder used by an application's authenticated
thread facade. These libraries carry values only: they do not admit an
application, select a workspace, open a store, or grant access to a thread.

| Entry | Responsibility |
|---|---|
| `client`, `arguments`, `interaction` | Application launch and broker-facing values used by standalone application processes |
| `caller`, `text`, `status_reader`, `status_surface` | Typed owner replies and bounded presentation values |
| `appearance`, `names` | Shared semantic presentation values for applications and desktop consumers |
| `frame` | The application frame every Bee application draws with: header, tabs, action bar, status and key-hint footer, list window, table and empty state |
| `thread_protocol` | Exact bounded requests and replies for the authenticated application-to-broker thread facade |

Applications still run as standalone processes. The host admits their exact
definition and policies; the broker supplies execution identity and durable
thread bindings. Registry metadata and SDK imports do not authorize an
application or a thread operation.
