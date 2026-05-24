# agent instruction

**§6.X — No assignment to bash readonly built-in variables.** Never write `UID=…`, `EUID=…`, `BASHPID=…`, `RANDOM=…`, `LINENO=…`, `SECONDS=…` in any bash script committed to this repo. Under `set -u` the assignment silently fails and the variable retains its built-in value (usually the runtime's process UID), which downstream code uses with confusing consequences. Defended by `tests/unit/test_shell_readonly_var_assignment.sh`.

*Grounded in: tests/integration/11_platform_secret_e2e.sh used `UID=$(kubectl get xplatformsecret …)`. The assignment was rejected silently; `$UID` retained the runner's 1001; `ASM_KEY=k8-platform/1001` collided across runs; every ASM put failed with `ResourceNotFoundException`.*

# justification

The bug class is invisible without the lint — `set -u` doesn't abort, and `set -e` doesn't either. The lint costs ~30s to author and runs in milliseconds. The bug it prevented took two hours of session time to root-cause and was hidden behind a silent-PASS for a session and a half.

---
