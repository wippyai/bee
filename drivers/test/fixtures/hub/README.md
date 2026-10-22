The Hub package inspection suites own `root_pack.json.gz`. It preserves entry identities, metadata, requirements and binary identity from Bee pack `sha256:cc162914f9d61c2a46a532c06dbb940e89d2dabd43dfd078f843c904c051fb11`; executable bodies are omitted. The snapshot is independent of the live registry so package inspection exercises a published artifact.

`make compose` expands it into the ignored Lua data library. To replace the snapshot, run from the pinned runtime module:

```sh
go run /path/to/bee/tests/fixtures/hub_pack_fixture.go pack.wapp > /path/to/bee/tests/fixtures/hub/root_pack.json.gz
```
