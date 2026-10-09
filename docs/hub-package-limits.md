# Hub package planning limits

`bee.hub.package:limits` owns the entry-count envelope: 4,096 entries per
package and 16,384 entries per captured registry state. Package inspection,
requirement decoding, migration projection/capture, resident and downloaded
artifact collection, and binary-identity decoding use the same package limit.
Catalog application detection uses the package limit too. Inventory and
migration snapshot readers use the state limit.

These are Bee planning limits, not WAPP format limits. The package limit is
the existing resident/downloaded artifact planning envelope from
`src/hub/binding/artifact_source.lua`; the state limit is the existing inventory
and migration-work snapshot envelope. Centralizing those policies removes
the narrower 512-entry decoders and the separate 10,000-entry identity decoder.
The limits bound the number of Lua rows, indexes and projections allocated or
traversed while inspecting untrusted package content. They do not bound payload
bytes or promise a fixed heap size. Removing all count limits would let one
artifact amplify memory and planning work across these projections.

At runtime revision `447ddfa912f343914f442b002bde95ff3cd349c3`,
`boot/deps/hub/module_entries.go:loadEntriesFromWapp` opens a WAPP reader and
`boot/deps/packentries/decode.go:Decode` decodes the complete entry slice without
an entry-count limit. The pinned `github.com/wippyai/wapp`
`v0.1.3-0.20261003195239-f1e565edf8ff` reader checks SHA256 and frame bounds and
limits the data section to `1 << 30` bytes (`reader.go:maxDataSize`); its default
decompression cache is 64 MiB. Neither byte limit supplies a suitable Lua
planning row count. The Lua Hub package handle likewise returns the full
decoded entry list. Bee therefore retains its own finite planning envelope.

## Measured packages

The regression fixture comes from the actual published
`bee/bee@0.2.0-selfupdate.1` pack, SHA256
`285cf343fc61ecca87eafb6901846b70dcb2b1e774004261fcee5e767cc3d639`.
It preserves every entry identity/kind/metadata and requirement, dependency and
binary-identity data; executable bodies are omitted. Tests derive the package
size from that list, not a hard-coded count or the configured limit.

| Package | Entries | Requirements | Most targets per requirement | Dependencies | Migrations | Process services |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| bee/bee 0.2.0-selfupdate.1 | 1433 | 3 | 1 | 2 | 53 | 15 |
| wippy/bootloader 0.3.17 | 11 | 2 | 1 | 2 | 0 | 1 |
| wippy/migration 0.3.21 | 11 | 1 | 1 | 2 | 0 | 0 |
| wippy/security 0.4.3 | 3 | 0 | 0 | 0 | 0 | 0 |
| wippy/terminal 0.4.6 | 2 | 0 | 0 | 0 | 0 | 0 |
| wippy/test 0.4.19 | 9 | 0 | 0 | 1 | 0 | 0 |

The package envelope allows 2.85 times the measured Bee root size; all six
packages total 1,469 entries, below the separate state envelope. A future pack
that outgrows the envelope needs an explicit policy review, not an automatic
limit increase derived from untrusted input.

Other bounds on this path measure different things and remain unchanged:

- Requirements, parameters and targets: 128 each; measured maxima are 3, 2
  and 1. Target paths allow 512 bytes (maximum 19); parameter/default values
  allow 16,384 bytes (maximum default JSON 35 bytes).
- Migration work/receipts: 128 migrations; measured 53. Snapshot row counts
  use the state envelope rather than the former unrelated `128 * 16` formula.
- Lifecycle work: 128 services; measured at most 16 across the closure.
- Dependencies/roots: 128; six packages and two direct Bee declarations fit.
  Graph closure: 64 modules; graph inspection: 128 artifacts; search: 512
  iterations. Inventory/resolution/receipt lists capped at 512 count modules,
  not registry entries.
- Native identity: 128 components; the pack declares one. Native requirement
  lists allow 64 per definition. Resource lists allow 512; Bee embeds one
  documentation filesystem.
- Inspection pages (32), installed manifest pages (256), catalog/version
  pages (100), and file/source byte windows paginate output; they are not
  whole-package entry limits. Message, identifier and path length bounds
  are likewise independent of entry counts.

Regenerate the structural fixture with the pinned runtime module as the Go
working directory (TMPDIR must point to an authorized scratch directory):

```sh
go run /path/to/bee/tests/tools/hub_pack_fixture.go /path/to/bee.wapp > /path/to/bee/tests/lua/hub/root_pack_fixture.lua
```
