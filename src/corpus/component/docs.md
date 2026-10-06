# bee.docs

The offline platform documentation a bound agent reads through the gateway
`docs` MCP tool.

The host composition holds one `fs.directory` entry, `bee.env:docs_corpus`,
pointing at `src/corpus`. `wippy.yaml` names it in its `embed:` list, so
`make build` packs it into the application as a read-only `fs.embed` volume; an
installed Bee serves it with no network. An agent can read the corpus and never
change it.

`src/corpus/manifest.json` records every document's id, topic, byte count and
SHA-256 digest. `tools/corpus.py` regenerates the reference driver pages and the
manifest; `make lint` runs `python3 tools/corpus.py --check`, which fails when a
page or a manifest record differs from the source.

`bee.docs.binding:call` is the read-only facade the gateway's `docs` tool calls.
`bee.docs:protocol` decodes one strict request:

| Operation | Fields | Bound |
|---|---|---|
| `list` | `topic?`, `offset?`, `limit?` | 64 documents per page |
| `search` | `query`, `topic?`, `offset?`, `limit?` | 16 matches per page, each with the section it sits under |
| `read` | `id`, `section?`, `offset?`, `limit?` | 16384 bytes per window |

`bee.docs:protocol` `web` decodes the live operations, which read the
documentation site the corpus is selected from, at the manifest's `base`
(`https://wippy.ai/llm`), through `bee.docs.binding:web`:

| Operation | Fields | Reads |
|---|---|---|
| `web_search` | `query`, `offset?`, `limit?` | `<base>/search?q=<query>` |
| `web_read` | `path`, `offset?`, `limit?` | `<base>/path/en/<path>`, a page path from `web_toc` or a search result |
| `web_toc` | `offset?`, `limit?` | `<base>/toc` |
| `web_index` | `offset?`, `limit?` | the site's curated `llms.txt` |

Each answers one window of at most 16384 bytes with `next_offset` and `eof`.
`bee.security.docs:docs_web_policy` allows `http_client.request` only to
`https://wippy.ai/llm/` and `https://wippy.ai/llms.txt`; the site being
unreachable reports `UNAVAILABLE`, a missing page `NOT_FOUND`.

Document ids match `^[%w_./:-]+$` up to 160 bytes. The facade opens the one
volume and holds no writer, no registry publication and no host path. The host
fills `bee.docs.env:corpus_ref` through `target_corpus`, and
`bee.security.docs:docs_policy` grants only that reference and its volume.
