# Agents and apps

How an agent session works with the apps installed in its workspace: start an
app on the person's desktop, send it a message while it runs, call its app
tools, and talk with the person on the bound thread.
Searches that lead here: start an app, open app, open application window,
send message to app, talk to running app, app tools.
Every tool below is an MCP tool of your session.

## Access you request

Some tools reach you only after the person approves them. Read what you have
with `capabilities` or `session` `{operation: "read"}`: `requestable_access`
names the traits you may ask for, and `tools` lists what is active.

| Trait | Gives | Ask for it when |
|---|---|---|
| `bee.app:runtime` | `application_open` | you start an app or send a running app new arguments |
| one trait per installed app with tools, e.g. the counter's | that app's tools by name, e.g. `counter_list` | you call an app's tools |
| `bee.app:tools` | `app_tools` (listing) when no installed app offers tools yet | you look for app tools |

Request and wait:

1. `session` `{operation: "request_access", idempotency_key: "<stable key>", traits: ["bee.app:runtime"], reason: "<what you will do>"}`
   returns `approval_id`. The person sees the request in Needs you, with the
   trait's title (for `bee.app:runtime`, "Open apps on your desktop") and your reason.
2. Poll `session` `{operation: "access_status", approval_id}` until `status` is
   `granted`. The trait is then active; call `tools/list` again to see its tools.

## Find the app

`application_open` takes the app's definition id: the `process.lua` entry with
`meta.type: bee.application`. For an app you delivered it is the id in your
`entries.json`, for example `app.hello.app:app`. An installed app that offers
tools also appears in `session` read `traits`, with its definition id as
`application_ref`. No tool lists every installed app; ask the person on the
thread when you do not know the id.

## Start an app (open app)

`application_open` `{definition_id: "app.hello.app:app", arguments: ["Ada"], idempotency_key: "greet-ada"}`

The node opens the app in a window on the desktop the person shows for your
workspace, the same way the person starts it from the Apps menu, and brings
it forward. Only apps applied and admitted in your workspace open. Arguments
are literal strings (at most 16, 1024 bytes each) that the app reads as
`launch.arguments`. The result names `instance_id`, `view_id`, `desktop`,
`title` and `reused`. Retrying with the same `idempotency_key` returns the
window the first attempt opened instead of opening another.

## Send a message to a running app (talk to running app)

Open the app again with the message as its arguments. An app declared with
`instance_policy: singleton` that already runs on that desktop is not started
again: the node delivers the arguments to the running window as navigation,
and the result has `reused: true`. The app receives them on the
`bee.app.navigate` topic and reads them with `client.navigation(launch,
sender, payload)`; `reference_apps/starter` shows the whole loop (the Hello app
greets the name it is opened or navigated with). Use a new `idempotency_key` per
message.

An app cannot register a process name, and an app tool runs as its own
instance of the app, not inside the window, so neither a name lookup nor a
tool reaches the running window. Navigation through `application_open` is the
one path. A database the app polls is not needed for this.

## Call app tools

An installed app with an `agent.tools` capability offers functions to agents
(`docs/app_capabilities` declares them). Request that app's trait as above;
once granted, its tools appear by alias in `tools/list`. Call one directly,
for example `counter_list` `{}`, or through `call_tool` `{name:
"counter_list", arguments: {}}`. A tool runs as the app with the app's own
grants and works on the app's state, such as its database; it returns
`{ok, value}` or `{ok: false, error: {code, message}}`.

## The bound thread

Your session is bound to one thread. `thread_read` `{cursor: 0, limit: 32}`
reads its records; `thread_message` `{idempotency_key, message_id,
message_kind: "progress", content: {text: "..."}}` records a note the person
sees. Apps do not read this thread; give an app input through
`application_open` arguments or its tools.

## Errors and what to do

| You see | Cause | Do |
|---|---|---|
| JSON-RPC error `tool is not admitted for this binding` | the tool's trait is not active | request the trait (Access you request) |
| `request_access` `DENIED`: `trait is not requestable` | your launch does not offer that trait | ask the person to start you with a profile that offers it |
| `DENIED`: `application runtime access is not active` | `bee.app:runtime` granted but deselected | `session` `{operation: "select", expected_revision, active_traits: [..., "bee.app:runtime"], context: {}}` |
| `FAILED`: `no display shows a desktop of workspace <id>` | the person is not looking at a desktop of your workspace | tell the person on the thread to show one, then retry with the same key |
| `FAILED`: `unknown app <id>` or `<id> is not an app` | wrong definition id | use the `process.lua` app entry id |
| `FAILED`: `application has no admission: <id>` | the app is not installed in this workspace | deliver it (`docs/build_bee_app`) or ask the person to install it |
| JSON-RPC error `arguments must be an array of bounded literal strings` | non-string, control characters or too long | send short literal strings |
