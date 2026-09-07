# Optional desktop fixtures

Welcome and Colors are independent test applications. They are not loaded by
`./run.sh`, included in `wippy.lock`, or shipped in `dist/bee.wapp`.

`make check` composes them into a temporary test workspace with explicit admission
and launch arguments. This verifies desktop/application interaction without making
fixtures part of the core product.
