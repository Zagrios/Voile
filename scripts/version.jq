# Voile's version order, for jq -L scripts 'include "version"; ...': a release v<CrossOver version>-<revision>, such as
# v26.3.0-26, after its betas v26.3.0-26.beta<n>: v26.3.0-26.beta2 is [26, 3, 0, 26, 0, 2], v26.3.0-26 is
# [26, 3, 0, 26, 1, 0]. Any other name, such as d3dmetal-4.0-beta2, is null. Obelisk orders them the same way.
def order:
    ltrimstr("v")
    | (capture("^(?<release>[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+)(\\.beta(?<beta>[0-9]+))?$") // null)
    | if . == null then null
      else [.release | splits("[.-]") | tonumber] + (if .beta then [0, (.beta | tonumber)] else [1, 0] end) end;
