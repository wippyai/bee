# Bee values

`bee.values` owns reusable validation and encoding helpers with no registry,
process, SQL, or terminal authority. `bee.values:bounds` checks bounded strings,
identifiers, numbers, lists, objects, fields, and relative paths. Its timestamp
decoder uses the shared clock parser.

`bee.values:canonical` encodes JSON with sorted object keys, preserved runtime
empty-table shape, and caller-selected byte and depth limits. `bee.values:time`
formats UTC timestamps and measures elapsed time. `bee.values:reply` decodes
the shared service reply envelope. Domain-specific capacities and wire limits
remain in the subsystem that owns them.
