# Runtime patch composition

`runtime-http-port0.patch` is runtime PR
[#737](https://github.com/wippyai/runtime/pull/737), commit
`20e657b4ee1f6f3d5bd71325d540da8095a0cfce`, applied to Bee's selected runtime
`291f5c6b708c80afe5da07f3223767573b4d183f`. The upstream PR is merged. Bee still
needs the launch ABI from its selected pin, so this patch composes the upstream
HTTP fix without changing that ABI. `wippy.build.json` verifies the patch digest.

The patch preserves native HTTP listener ownership and reports the bound address
when port zero is selected. Remove this composition when the selected runtime
contains both requirements. Upstream file licenses remain unchanged.
