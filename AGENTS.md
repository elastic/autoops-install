# Agent Instructions

## Keeping tests in sync

When modifying `tools/check_connectivity.sh`, always update `tools/test_check_connectivity.sh`
to reflect the changes:

1. Run `git diff tools/check_connectivity.sh` to identify what changed
2. Update any tests affected by modified behavior (HTTP codes, response body checks, environment variables, success/failure conditions)
3. Add new tests for any new functionality or environment variables
4. Run `bash tools/test_check_connectivity.sh` to verify all tests pass
5. Fix any failing tests before finishing

The same applies to `upgrade/upgrade_autoops.sh` and `upgrade/test_upgrade_autoops.sh`:
update or add tests for every behavior change, and run `bash upgrade/test_upgrade_autoops.sh`.
The tests use mock `kubectl`, `docker` and `podman` commands, so they need no cluster or
container runtime.

## Upgrade script rules

`upgrade/upgrade_autoops.sh` runs on customer machines against a working agent:

- Never print, log or send secret values. Show environment variables by name only.
- `--dry-run` must not change anything.
- Never change an install without confirmation (`--yes` or an interactive prompt).
- Every change must be reversible: restore the previous version when the new one fails.
