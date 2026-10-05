# "TTY"

_Path: en/lua/system/tty_

> "Terminal input events, styled output, presentation surfaces, and local virtual viewports."

## Table of Contents

- TTY

## Content

# TTY

<secondary-label ref="process"/>
<secondary-label ref="io"/>

Terminal input events, styled output, presentation surfaces, and local virtual viewports.

<note>
Every function resolves the terminal port attached to the calling process frame. A process on a <a href="system/terminal.md">Terminal Host</a> owns the physical terminal; a <code>process.lua</code> on a regular <code>process.host</code> owns a virtual terminal when it is spawned with a viewport grant. Without either attachment the module returns "no terminal context".
</note>



## Loading


```lua
local tty = require("tty")
```



## Model


A **Surface** is one process's exclusive presentation lease on its terminal port. It publishes complete row snapshots; the backend owns diffing and terminal recovery. Only one surface may be open on a port at a time.

A **Canvas** is an in-process styled-cell composition buffer. It clips at cell boundaries and never emits terminal control commands of its own.

A **Viewport** is a local, structured terminal boundary that lets one process host another process's surface without sharing byte streams. The shell decides where viewport content appears and translates input into the child's coordinates; the child sees an ordinary terminal port and does not know whether it is full-screen, tiled, tabbed, or hidden.

Viewports are local to one runtime node. Grants and handles are opaque local capabilities, not serializable network references.



## Input Loop


Start input delivery, subscribe to events, and process them in a loop:

```lua
local tty = require("tty")
local io = require("io")

local function handler()
    local events = tty.events()
    tty.start()

    while true do
        local ev, open = events:receive()
        if not open then break end

        if ev.type == "key" then
            if ev.key == "q" or (ev.ctrl and ev.key == "c") then
                break
            end
            local _, print_err = io.print("Key: " .. ev.key)
            if print_err then loop_err = print_err; break end

        elseif ev.type == "resize" then
            local _, print_err = io.print("Size: " .. ev.width .. "x" .. ev.height)
            if print_err then loop_err = print_err; break end
        end
    end

    local _, stop_err = tty.stop()
    if loop_err then return nil, loop_err end
    if stop_err then return nil, stop_err end
    return started
end
```

Call `events()` before `start()` so a consumer is ready when the first events arrive. On a virtual port, `start()` opens viewer-to-producer event delivery and `stop()` closes it: a `Viewport:send()` outside that interval fails instead of silently dropping input. Resize delivery is independent of input state.



### `tty.start()`


Start input delivery for the current port. A physical terminal switches to raw mode.

```lua
local ok, err = tty.start()
```

**Returns:** `boolean, error`



### `tty.stop()`


Stop input delivery and restore the terminal to normal mode.

```lua
local ok, err = tty.stop()
```

**Returns:** `boolean, error`



### `tty.events()`


Subscribe to the port's terminal events and return a channel. Events are delivered as tables with a `type` field. Subscribe once and reuse the channel.

```lua
local events, err = tty.events()
```

**Returns:** `EventChannel, error`

`EventChannel` has `receive()` and `case_receive()`, so it composes with `channel.select`.



### tty.screen_size()


Read the current terminal dimensions.

```lua
local width, height, err = tty.screen_size()
```

**Returns:** `number, number, error`



### `tty.mouse(enable)`


Enable or disable mouse event tracking.

```lua
local ok, err = tty.mouse(true)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `enable` | boolean | `true` to enable, `false` to disable |

**Returns:** `boolean, error`



## Surface


A surface is the port's presentation lease. Acquire one, publish complete frames, and close it when done.



### tty.surface(options?)


```lua
local surface, err = tty.surface({
    alternate_screen = true,
    hide_cursor = true,
    synchronized_output = true,
})
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `alternate_screen` | boolean | false | Present on the terminal's alternate screen buffer |
| `hide_cursor` | boolean | false | Hide the terminal cursor while the surface is open |
| `synchronized_output` | boolean | false | Wrap each frame in synchronized-output markers |

**Returns:** `Surface, error`

Opening a second surface on a port that already has one fails. A virtual port keeps the options as surface metadata; a physical port translates them into terminal modes and restores them on close.



### surface:present(rows, options?)


Publish a complete array of row strings. Row `1` is the top line.

```lua
local stats, err = surface:present(rows, {
    cursor = {x = 12, y = 3, visible = true},
    images = {
        {placement_id = "logo", image = logo, x = 2, y = 2, cols = 20, rows = 8, alt = "Logo"},
    },
})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `rows` | string[] | Complete frame, at most 16384 rows |
| `options.cursor` | table | `{x, y, visible}` in one-based surface coordinates |
| `options.images` | table[] | Complete retained-image placement set for the frame |

Omitting `cursor` preserves the last explicit cursor state. All three cursor fields are required when `cursor` is present.

**Returns:** `stats, error` — an immutable record with `rows`, `changed_rows`, and `bytes_written`. A physical frame identical to the previous one writes nothing.



### surface:invalidate()


Forget backend presentation state without erasing the logical frame. The next `present` commits even when its rows are unchanged. Use it after an outer terminal resize or when another owner may have disturbed physical state.

**Returns:** `boolean`



### surface:close()


Release the lease. Idempotent: later calls return the first close result. A physical backend restores terminal modes.

**Returns:** `boolean, error`



### surface:capabilities()


Return `{images = "native" | "kitty" | "pending" | "none"}`. Start terminal
input before probing. A physical backend may briefly return `pending` while it
queries the terminal; virtual surfaces retain images without probing.

**Returns:** `table, error`



### surface:clipboard(text)


Write an OSC 52 clipboard request on a physical surface. Text must be valid
UTF-8 and at most 65,536 bytes. Success means the terminal output accepted the
request; terminal policy may still ignore it. Virtual surfaces return an
unsupported error, and the API provides no clipboard read or acknowledgement.

**Returns:** `boolean, error`



## Retained Images


Import a PNG into bounded runtime storage, then place its handle in a complete
surface frame:

```lua
local image = assert(tty.image(png_bytes))
local info = image:info() -- id, format, width, height, bytes

assert(surface:present(rows, {images = {{
    placement_id = "preview",
    image = image,
    x = 1, y = 1, cols = 40, rows = 12,
    src = {x = 0, y = 0, width = info.width, height = info.height},
    z = 1,
    alt = "Preview",
}}}))
```

`tty.image()` validates PNG bytes asynchronously. `image:read()` explicitly
exports the encoded bytes and `image:close()` releases the reference. Source
pixel coordinates are zero-based; destination cell coordinates are one-based.
Omitting `images` from a later `present` clears prior placements. Unsupported
physical terminals display the placement's `alt` text, while virtual surfaces
keep the image resource for viewers.



## Canvas


A canvas is a bounded styled-cell buffer used to compose a frame before presenting it.



### tty.canvas(width, height)


```lua
local canvas = tty.canvas(width, height)
```

Width is capped at 16384 columns, height at 16384 rows, and the area at 262,144 cells. Out-of-range arguments raise an argument error.

**Returns:** `Canvas`

Drawing accepts styled text, not terminal commands. SGR colors and OSC 8 links are preserved; erase, cursor-motion, and other control-only output is not emitted. Each placement is clipped independently at cell boundaries with grapheme-width awareness, so a clipped escape sequence cannot leak into neighboring content.



### canvas:clear(fill?)


Clear every cell. An optional styled `fill` string is repeated across each row.

```lua
canvas:clear()
canvas:clear(tty.style():background("#1a1a1a"):render(" "))
```

**Returns:** `boolean`



### canvas:put(x, y, text, width?)


Place one styled row at one-based `x`, `y` and clip it to `width` cells (default: the canvas width). Coordinates may be negative or past the edge; the placement is clipped rather than rejected. A newline ends the row, so use `put_rows` for multi-row content.

```lua
canvas:put(3, 1, tty.style():bold():render("Title"), 40)
```

**Returns:** `boolean`



### canvas:put_rows(x, y, rows, width?)


Place an array of styled rows starting at `x`, `y`, one row per line downward. Every entry is validated before anything is drawn.

```lua
canvas:put_rows(2, 2, child_rows, inner_width)
```

**Returns:** `boolean`



### canvas:rows()


Render the complete row array, ready for `surface:present`.

**Returns:** `string[]`



## Viewport


A viewport is a virtual terminal port. The creating process is its first viewer; the process admitted with its grant is its producer.



### tty.viewport(options?)


```lua
local view, err = tty.viewport({
    width = 80,
    height = 24,
    page = {foreground = "#e0def4", background = "#191724"},
})
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `width` | number | 80 | Columns, 1 to 65535 |
| `height` | number | 24 | Rows, 1 to 65535 |
| `page` | table | none | Opaque `#RRGGBB` foreground and background defaults |

The area is capped at 262,144 cells.

**Returns:** `Viewport, error`



### tty.attach(handle)


Add another local viewer to an existing viewport. A handle grants viewing, never presentation ownership, and is not valid on another node.

```lua
local view, err = tty.attach(handle)
```

**Returns:** `Viewport, error`



### viewport:grant()


Return the one-shot producer capability. Pass it as the `terminal` spawn option:

```lua
local grant = assert(view:grant())
local child = assert(process.with_options({terminal = grant})
    :spawn_monitored("app:child", "app:workers"))
```

Admission consumes the grant transactionally: a rejected start restores an unresolved grant, while a process that has resolved the port consumes it permanently. A host that does not support terminal attachments rejects the spawn instead of dropping the option. See [Processes](lua/core/process.md#spawner-with-options).

**Returns:** `string, error`



### viewport:handle()


Return the local viewer handle for `tty.attach`.

**Returns:** `string`



### viewport:snapshot(after_revision?)


Read the current dimensions, rows, cursor, and revision. With `after_revision`, return `nil` when the revision is unchanged.

```lua
local frame = view:snapshot(revision)
if frame then
    revision = frame.revision
    canvas:put_rows(2, 2, frame.rows, inner_width)
end
```

**Returns:** `snapshot` or `nil`

| Field | Type | Description |
|-------|------|-------------|
| `revision` | number | Monotonic revision of this frame |
| `width` | number | Viewport columns |
| `height` | number | Viewport rows |
| `rows` | string[] | Rows last published by the producer |
| `cursor` | table | `{x, y, visible}` in one-based coordinates, absent until the producer publishes explicit cursor state |
| `images` | table[] | Retained image placement metadata |
| `layers` | table[] | Ordered presentation layers |
| `images_omitted` | boolean | Image resources exist but are not retained by this plain snapshot |

A page resolves terminal-default cells and omitted rows to explicit colors. The
creator can change it with `viewport:set_page(page)`; passing `nil` restores the
producer's original rows. Page changes advance the revision without requiring
the producer to repaint.



### viewport:updates()


Return a channel of coalesced revision watermarks. `receive()` yields the revision number; `case_receive()` composes with `channel.select`.

```lua
local updates = assert(view:updates())
```

Updates are bounded hints, not an event log. A slow viewer receives only the newest watermark and must call `snapshot()` for state. Presentation and resize never block on a slow viewer.

**Returns:** `ViewportUpdateChannel, error`



### viewport:send(event)


Forward a validated event record to the producer. The producer must have called `tty.start()`; otherwise the call fails rather than dropping the event.

```lua
assert(view:send(event))
assert(view:send({type = "close"}))
```

**Returns:** `boolean, error`



### viewport:resize(width, height)


Update the viewport geometry. When the size changes, viewers get a new revision and the producer receives a `resize` event.

**Returns:** `boolean, error`



### viewport:close()


Detach this viewer only. Closing the last viewer does not kill a live producer, and closing the producer's port does not destroy state while viewers remain.

**Returns:** `boolean, error`



### viewport:mount(recipient_pid, rights)


Issue a process-bound reference for a local or remote viewer. Rights are
independent and default to false:

```lua
local observation = assert(view:mount(agent_pid, {observe = true}))
local control = assert(view:mount(agent_pid, {input = true, resize = true}))

-- In the exact recipient process, on this node or an authenticated mesh peer:
local observer = assert(tty.attach(observation))
local controller = assert(tty.attach(control))
```

A mount is bound to the recipient's full PID and can be redeemed only once.
Mounted viewers cannot create producer grants or delegate further mounts.
Remote mounts use a renewable lease; reconnecting requires a fresh mount and
cannot replay terminal input. Use `viewport:revoke(reference)` to revoke an
issued mount. Closing the owner viewport or ending the owner process revokes
its mounts.



### viewport:capture()


Atomically pin a viewport revision and its retained image resources:

```lua
local capture = assert(view:capture())
local snapshot = capture:snapshot()
local image = assert(capture:image(snapshot.images[1].image_id))
assert(capture:close())
```

A plain `snapshot()` does not retain image bytes. A capture does until closed;
image handles already acquired from it remain independently owned.



## Event Types


Events are tables with a `type` field that determines which other fields are present. Coordinates are one-based. The same records are accepted by `viewport:send()`.



### Key Event


```lua
{
    type = "key",
    key = "a",           -- printable character or key name
    key_type = "runes",  -- "runes" for printable, or special key name
    action = "press",    -- "press" or "release"
    alt = false,
    ctrl = false,
    shift = false
}
```



### Mouse Event


Requires `tty.mouse(true)`.

```lua
{
    type = "mouse",
    action = "press",    -- "press", "release", "motion", "wheel"
    button = "left",     -- button name
    x = 10,
    y = 5,
    alt = false,
    ctrl = false,
    shift = false
}
```



### Resize Event


```lua
{type = "resize", width = 120, height = 40}
```



### Start Event


Emitted once after `tty.start()` with initial dimensions.

```lua
{type = "start", width = 120, height = 40}
```



### Focus Event


Reports keyboard ownership.

```lua
{type = "focus", focused = true}
```



### Visibility Event


Reports whether repainting is useful. It does not prescribe application lifecycle or background computation.

```lua
{type = "visibility", visible = true}
```



### Paste Event


```lua
{type = "paste", text = "pasted content"}
```



### Close Event


Asks the producer to shut down. A shell sends it through `viewport:send` to request a graceful child exit.

```lua
{type = "close"}
```



## Key Bindings


Create reusable key bindings that match against key events:

```lua
local quit = tty.bind({
    keys = {"q", "ctrl+c"},
    help = {key = "q/ctrl+c", desc = "quit"}
})

-- In event loop
if quit:matches(ev) then
    break
end
```



### `tty.bind(config)`


| Field | Type | Description |
|-------|------|-------------|
| `keys` | string[] | Required. Key patterns to match (e.g. `"a"`, `"ctrl+c"`, `"enter"`) |
| `help` | table | Optional. `{key = "...", desc = "..."}` for help text |

**Returns:** `KeyBinding`

The type schema requires `keys`. At runtime, an omitted or empty `keys` table creates a binding that never matches.



### KeyBinding Methods


| Method | Returns | Description |
|--------|---------|-------------|
| `matches(event)` | boolean | Test if a key event matches this binding |
| `set_enabled(bool)` | self | Enable or disable the binding |
| `is_enabled()` | boolean | Check if the binding is enabled |
| `help()` | table | Returns `{key, desc}` help info |



## Styles


Create styled terminal output. Style values are immutable, so each style method returns a new value.

```lua
local tty = require("tty")
local io = require("io")

local title = tty.style()
    :bold()
    :foreground("#FF0000")
    :padding(0, 1)

local box = tty.style()
    :border(tty.borders.ROUNDED)
    :border_foreground("#00FF00")
    :width(40)
    :padding(1, 2)

local _, print_err = io.print(box:render(title:render("Hello"), "World"))
if print_err then return nil, print_err end
```



### `tty.style()`


Create an empty style.

**Returns:** `Style`



### Style Methods


All methods return a new `Style` and can be chained.



#### Text Decoration


| Method | Parameter | Description |
|--------|-----------|-------------|
| `foreground(color)` | string | Text color (hex `"#FF0000"`, ANSI `"9"`, or name) |
| `background(color)` | string | Background color |
| `bold(enable?)` | boolean | Bold text (default: true) |
| `italic(enable?)` | boolean | Italic text |
| `underline(enable?)` | boolean | Underline text |
| `strikethrough(enable?)` | boolean | Strikethrough text |
| `faint(enable?)` | boolean | Dimmed text |
| `blink(enable?)` | boolean | Blinking text |
| `reverse(enable?)` | boolean | Swap foreground/background |



#### Layout


| Method | Parameter | Description |
|--------|-----------|-------------|
| `width(n)` | number | Fixed width |
| `height(n)` | number | Fixed height |
| `max_width(n)` | number | Maximum width |
| `max_height(n)` | number | Maximum height |
| `padding(...)` | numbers | Padding (CSS-style: top, right, bottom, left) |
| `margin(...)` | numbers | Margin (CSS-style) |
| `align(pos)` | number | Horizontal alignment |
| `align_vertical(pos)` | number | Vertical alignment |
| `inline(enable?)` | boolean | Inline rendering mode |



#### Borders


| Method | Parameter | Description |
|--------|-----------|-------------|
| `border(name, ...)` | string, booleans | Border style, optional per-side toggles |
| `border_foreground(...)` | strings | Border color(s) |
| `border_background(...)` | strings | Border background color(s) |



#### Other


| Method | Description |
|--------|-------------|
| `render(...)` | Render strings with this style applied |
| `copy()` | Create a copy of this style |



### Border Constants


```lua
tty.borders.NORMAL
tty.borders.ROUNDED
tty.borders.THICK
tty.borders.DOUBLE
tty.borders.HIDDEN
```



### Alignment Constants


```lua
tty.align.LEFT    -- 0
tty.align.CENTER  -- 0.5
tty.align.RIGHT   -- 1
```



## Text Utilities


The `tty.text` subtable provides layout and measurement functions for styled text.



### Measurement


```lua
local w = tty.text.width("hello")         -- printable width (ANSI-aware)
local h = tty.text.height("a\nb\nc")      -- line count
local w, h = tty.text.size("hello\nworld") -- both
```



### Clipping


```lua
-- Truncate to a printable width, with an optional tail
local head = tty.text.truncate(line, 40)
local head = tty.text.truncate(line, 40, "…")

-- Take the printable cell range [left, right)
local middle = tty.text.cut(line, 10, 30)
```

Both preserve ANSI state and grapheme boundaries, so styled text can be clipped and spliced without breaking escape sequences. `truncate` returns an empty string for a width of zero or less; `cut` returns an empty string when `right` is not greater than `left`.



### Joining


```lua
-- Join side by side, aligned at top
local row = tty.text.join_horizontal(tty.text.position.TOP, left, right)

-- Stack vertically, centered
local col = tty.text.join_vertical(tty.text.position.CENTER, top, bottom)
```



### Max Dimensions


```lua
local w = tty.text.max_width({"short", "a longer string"})   -- widest
local h = tty.text.max_height({"one\ntwo", "single"})         -- tallest
```



### Placement


Place a string within a box with the given dimensions:

```lua
-- Center in a 80x24 box
local out = tty.text.place(80, 24, tty.text.position.CENTER, tty.text.position.CENTER, content)

-- Horizontal only
local out = tty.text.place_horizontal(80, tty.text.position.RIGHT, content)

-- Vertical only
local out = tty.text.place_vertical(24, tty.text.position.BOTTOM, content)
```



### Position Constants


```lua
tty.text.position.TOP      -- 0
tty.text.position.LEFT     -- 0
tty.text.position.CENTER   -- 0.5
tty.text.position.BOTTOM   -- 1
tty.text.position.RIGHT    -- 1
```



## Permissions


Access to a physical terminal comes from the process frame. Attaching a
producer with `process.with_options({terminal = grant})` requires
`process.context` on the spawning side. Delegated viewports additionally check:

| Action | Resource | Description |
|--------|----------|-------------|
| `tty.mount` | Owner viewport handle | Issue a process-bound mount |
| `tty.observe` | Owner viewport handle | Read snapshots, updates, and captures |
| `tty.input` | Owner viewport handle | Forward input events |
| `tty.resize` | Owner viewport handle | Resize the viewport |



## See Also


- [Terminal UI](tutorials/tty.md) — build a shell that hosts a child in a viewport
- [Terminal I/O](lua/system/io.md) — stdin/stdout/stderr operations
- [Terminal Host](system/terminal.md) — Terminal host configuration
- [Command Execution](lua/dynamic/exec.md) — PTY processes and terminal sessions
- [Processes](lua/core/process.md) — spawn options, monitoring, lifecycle events



## Navigation

Previous: "OS Time" (lua/system/ostime)
Next: "Hub" (lua/system/hub)
