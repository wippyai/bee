# Thread journal fixture

This fixture is staged by `tests/threads.py` into a disposable Wippy project.
The owning gate is `make threads`.

It proves the local journal boundary through the real runtime:

- an owner, producer and subscriber communicate as separate processes;
- the owner authenticates participants and issues a bounded, read-only thread
  capability;
- append retries are idempotent, conflicting retries are rejected, and foreign
  thread reads are denied;
- committed records replay from an exclusive cursor across multiple pages, with
  per-thread isolation and resume behavior;
- the fixture migration ledger detects a changed migration checksum; and
- a native contract function has its own process and scope and cannot open the
  journal database directly.

The fixture is test-only and is not part of the Bee desktop or release pack.
The production thread contract is documented in [docs/THREADS.md](../../docs/THREADS.md).
