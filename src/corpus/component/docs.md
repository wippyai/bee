# bee docs

The offline platform documentation a bound agent reads through the gateway
`docs` tool.

The host composition holds one `fs.directory` entry, `bee:docs_corpus`, pointing
at the `src/corpus` snapshot. `wippy.yaml` names it in its `embed:` list, so `make pack`
and `make native-pack` freeze it into the root WAPP as a read-only `fs.embed` volume;
an installed Bee serves it with no network (`docs/operations/native.md`). The
volume is read-only at boot, so an agent can read the corpus and can never
change it.

The snapshot itself, its selection rule and its per-document sources, byte
counts and digests are built by `build/agent_corpus.py` (`make agent-corpus`) and
verified offline by `make agent-corpus-check`. The manifest is
`src/corpus/manifest.json`; a corpus change shows up as a digest change, so it
cannot rot silently.

`bee.docs.binding:call` is the read-only facade the gateway's `docs` tool calls. It decodes
one strict request (`list`, `search`, `read`), opens the one volume and answers
within the bounds `bee.docs:protocol` declares; it holds no writer, no registry
publication and no host path. The host fills `bee.docs:corpus_ref` through
`target_corpus` and names `bee:docs_policy` to grant only that reference and its
selected volume. The launch policies admit `docs` beside
`workspace` for every provider.
