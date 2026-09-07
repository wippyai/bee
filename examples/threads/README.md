# Local thread proof

This isolated example runs a journal owner, a test producer and a subscriber as
separate processes. It is not installed in the Bee desktop or portable pack.
The producer tests the current desktop model's empty scene and minimum bounds;
the subscriber prints committed test events. No external test command is run.

The subscriber also invokes a native contract probe. Its bound Lua function has
its own execution PID, retains the subscriber's security actor, and cannot open
the journal database. Exact binding/function and method grants admit that probe;
they do not grant arbitrary contract execution.

The typed `reader` library opens a native binding and exposes `read_after(cursor)`.
The owner issues a fresh, read-only capability at bootstrap, scoped to this one
thread and owner lifetime. Contract functions use their own reply address; they
do not impersonate the subscriber PID. The owner checks the capability, operation
and thread. It rejects append and foreign-thread reads even when a valid read
capability is supplied. This fixture capability is delegable bearer authority;
it is never a durable author ID or checkpoint value.

The subscriber catches up through that reader after each wakeup. Returned pages
are copied and checked for dense arrays, field bounds and increasing sequences.
The fixture's wait/done coordination remains private fixed-participant messaging;
it is not yet a general subscription SDK.

From the repository root, after `make setup`:

```sh
python3 examples/threads/run.py project-a --run run-a
python3 examples/threads/run.py project-a --run run-a
python3 examples/threads/run.py project-a --run run-b --after 4
make threads
```

The second invocation replays the same four events without appending duplicates.
The third appends a new run and reads after sequence 4. Omitting `--run` creates a
new run ID. `--after` is an exclusive, thread-local replay cursor, not an event
acknowledgement. The default database is `.wippy/thread-demo.db`; use `--db PATH`
for another persistent store. `BEE_RUNTIME` selects the runtime executable.

The owner binds authority to the actual producer/subscriber PIDs. Participants
cannot open its SQL resource, read another thread, or select an author identity.
Append receipts follow commit. Retries compare the exact event type and JSON
bytes; semantically equivalent JSON with different encoding is a conflict.

Limits: one writer and one reader, one outstanding wait, 64 events per read,
16 KiB bodies, 10,000 events per thread, one-second waits and a 15-second run
deadline. The journal persists; participant processes end with the invocation.
There are no durable subscriber cursors, background desktop runs, dynamic grants,
remote transport or general public thread API yet. See
[the proposed thread contract](../../docs/THREADS.md).
