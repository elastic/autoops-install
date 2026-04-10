# Agent Instructions

## Keeping tests in sync

When modifying `tools/check_connectivity.sh`, always update `tools/test_check_connectivity.sh`
to reflect the changes:

1. Run `git diff tools/check_connectivity.sh` to identify what changed
2. Update any tests affected by modified behavior (HTTP codes, response body checks, environment variables, success/failure conditions)
3. Add new tests for any new functionality or environment variables
4. Run `bash tools/test_check_connectivity.sh` to verify all tests pass
5. Fix any failing tests before finishing
