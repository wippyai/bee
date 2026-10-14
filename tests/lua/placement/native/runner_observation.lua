-- MIT. Test support: the native materialization runner reports no fixture state.
return {snapshot = function(): {[string]: unknown} return {} end}
