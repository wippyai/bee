# bee.driver.codex

The Codex harness component implements the shared Bee driver contract:
prepare and resume a launch, normalize protocol records, and render admitted
configuration. It contains no execution service or credential store. The host
selects activation, profiles, executable and permissions; this package grants
none of them. Placement owns execution and the credential broker owns login
materialization.

It is assembled as `bee/driver-codex`, separately from the shared
`bee/driver` contract and other harness bindings. It requires that contract,
its kit and thread-record decoders in the host composition. Native bundle
assembly does not establish independent Hub publication. See the shared
driver documentation for implemented authentication, MCP and recovery gates.
