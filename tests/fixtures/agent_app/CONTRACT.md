# Authoring one Bee desktop application

## The artifact

`entries.json` is a JSON list of complete native registry entries. Each entry has
`id`, `kind`, an optional `meta` and a required `data`. Configuration lives inside
`data`: `source`, `method`, `modules`, `imports`. Top-level YAML shorthand is not
the registry API and is refused. Source is inline text, never a file URL.

An application is one `process.lua` entry:

    {"id": "<namespace>:<name>", "kind": "process.lua",
     "data": {"source": "...", "method": "main",
              "modules": ["tty", "process", "channel", "json"],
              "imports": {"client": "bee.application:client"}},
     "meta": {"type": "bee.application",
              "application": {"api_version": 1, "lifetime": "view", "revision": "1",
                              "title": "...", "instance_policy": "multiple",
                              "resume_schema": "...", "restart_policy": "automatic"}}}

`meta.application` declares `api_version: 1`, `lifetime: view`, a nonempty
`revision` and `title`, and `instance_policy` of `singleton` or `multiple`.
`icon`, `group` and `role` are optional. Metadata describes the application; it
never authorizes it. The host separately admits the definition.

Declare every native module and library import the source actually uses, and
nothing else. Omit every optional configuration field you do not fill. An empty
list or an empty map reaches the destination as neither, and its preflight
refuses the version with `CONFIG_SHAPE`. Write no `"modules": []` and no
`"imports": {}`.

## The process

The broker starts the entry's `method` with one launch value. `client.launch(value)`
validates and copies it; a nil result means the launch is invalid and the process
must error. The returned record carries `broker_pid`, `workspace_id`,
`instance_id`, `view_id`, `definition_id`, `definition_revision`, `launch_token`,
`resume_schema`, `resume_state` and `arguments`.

    local launch = client.launch(value)
    if not launch then error("Invalid launch") end

`launch.resume_state` is the bytes of the last committed checkpoint, or `""` on a
first start. Decode it, refuse a shape you did not write, and start from it.

`client.ready(launch)` announces the first frame. Call it once, after the initial
paint.

`client.checkpoint(launch, state)` queues one checkpoint of at most 65536 bytes.
It needs a nonempty `resume_schema` in the definition metadata. A queued
checkpoint is not a commit. The broker answers with a `bee.application.checkpoint_result`
process message sent from `launch.broker_pid`; its payload data carries
`error_code`, empty on success. Subscribe before the first checkpoint:

    local receipts = assert(process.listen("bee.application.checkpoint_result", {message = true}))

and read the acknowledgment from the channel:

    local message = event.value
    local data = message:payload():data()
    if message:from() == launch.broker_pid and type(data) == "table" and data.error_code == "" then ... end

## The surface

    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()

Paint by building a canvas and presenting its rows:

    local canvas = tty.canvas(width, height)
    canvas:clear(" ")
    canvas:put(1, 1, "TEXT", width)
    assert(output:present(canvas:rows()))

`canvas:put(column, row, text, width)` uses one-based coordinates.

Select over the input, lifecycle and receipt channels with `channel.select`.
Input events carry a `type`:

- `key`: a keystroke; ignore the ones whose `action` is `release`.
- `resize`: carries `width` and `height`; re-read them and repaint.
- `close`: the view is closing; commit what must survive.

A lifecycle event of kind `process.event.CANCEL` ends the loop. On the way out
call `output:close()` and `tty.stop()`.

## Boundaries

Author only inside your Governance workspace, through the `workspace` tool. You
hold no registry publication, approval or activation capability, and you create
no security policy. The host reviews, lints, approves and applies your frozen
artifact; state nothing about checks you did not run.
