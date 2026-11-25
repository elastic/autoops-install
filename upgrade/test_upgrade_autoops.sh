#!/bin/bash
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License
# 2.0; you may not use this file except in compliance with the Elastic License
# 2.0.
#

# Test script for upgrade_autoops.sh
# Runs the script against mock kubectl, docker and podman commands that record
# every call, so no cluster or container runtime is needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPGRADE_SCRIPT="${SCRIPT_DIR}/upgrade_autoops.sh"

# ---------------------------
# Test framework
# ---------------------------

TESTS_PASSED=0
TESTS_FAILED=0

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

log_test() {
  echo ""
  echo -e "${YELLOW}TEST: $1${NC}"
  reset_mocks
}

log_pass() {
  echo -e "${GREEN}  PASS${NC}: $1"
  ((TESTS_PASSED++)) || true
}

log_fail() {
  echo -e "${RED}  FAIL${NC}: $1"
  ((TESTS_FAILED++)) || true
}

assert_exit_code() {
  if [[ "$RC" -eq "$1" ]]; then
    log_pass "Exit code is $1"
  else
    log_fail "Expected exit code $1, got $RC"
    echo "$OUTPUT" | sed 's/^/      | /'
  fi
}

assert_output_contains() {
  if grep -Fq -- "$1" <<<"$OUTPUT"; then
    log_pass "Output contains '$1'"
  else
    log_fail "Output should contain '$1'"
    echo "$OUTPUT" | sed 's/^/      | /'
  fi
}

assert_output_not_contains() {
  if grep -Fq -- "$1" <<<"$OUTPUT"; then
    log_fail "Output should NOT contain '$1'"
  else
    log_pass "Output does not contain '$1'"
  fi
}

# The call log has one line per mock command call, for example:
#   kubectl --namespace default set image deployment/x c=image:1
assert_called() {
  if grep -Fq -- "$1" "$MOCK_LOG"; then
    log_pass "Called '$1'"
  else
    log_fail "Should have called '$1'"
    sed 's/^/      | /' "$MOCK_LOG"
  fi
}

assert_not_called() {
  if grep -Fq -- "$1" "$MOCK_LOG"; then
    log_fail "Should NOT have called '$1'"
    sed 's/^/      | /' "$MOCK_LOG"
  else
    log_pass "Did not call '$1'"
  fi
}

# assert_call_order <first> <second>: both were called, in that order.
assert_call_order() {
  local first second
  first="$(grep -Fn -- "$1" "$MOCK_LOG" | head -n 1 | cut -d: -f1)"
  second="$(grep -Fn -- "$2" "$MOCK_LOG" | head -n 1 | cut -d: -f1)"
  if [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]]; then
    log_pass "Called '$1' before '$2'"
  else
    log_fail "Should have called '$1' before '$2'"
    sed 's/^/      | /' "$MOCK_LOG"
  fi
}

# ---------------------------
# Mock commands
# ---------------------------

MOCK_DIR="$(mktemp -d)"
MOCK_BIN="${MOCK_DIR}/bin"
MOCK_LOG="${MOCK_DIR}/calls.log"
MOCK_ENV_COPY="${MOCK_DIR}/env.copy"
mkdir -p "$MOCK_BIN"
trap 'rm -rf "$MOCK_DIR"' EXIT

cat >"${MOCK_BIN}/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$MOCK_LOG"
case " $* " in
  *" get deployments "*)
    [[ "${MOCK_K8S_UNREACHABLE:-}" == "1" ]] && exit 1
    [[ -n "${MOCK_K8S_DEPLOYMENTS:-}" ]] && printf '%s\n' "$MOCK_K8S_DEPLOYMENTS"
    exit 0
    ;;
  *" set image "*)
    exit "${MOCK_K8S_SET_IMAGE_RC:-0}"
    ;;
  *" rollout status "*)
    # Only the first rollout can be made to fail; the one after an undo succeeds.
    if [[ "$(grep -c ' rollout status ' "$MOCK_LOG")" -eq 1 ]]; then
      exit "${MOCK_K8S_ROLLOUT_RC:-0}"
    fi
    exit 0
    ;;
  *" rollout undo "*)
    exit "${MOCK_K8S_UNDO_RC:-0}"
    ;;
esac
exit 0
EOF

# docker and podman share one mock. MOCK_DOCKER_PS / MOCK_PODMAN_PS decide which
# runtime "has" containers.
cat >"${MOCK_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
runtime="$(basename "$0")"
echo "${runtime} $*" >>"$MOCK_LOG"

format=""
last=""
env_file=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "--format" ]] && format="$arg"
  [[ "$prev" == "--env-file" ]] && env_file="$arg"
  prev="$arg"
  last="$arg"
done

case "$1" in
  ps)
    if [[ "$runtime" == "docker" ]]; then
      [[ -n "${MOCK_DOCKER_PS:-}" ]] && printf '%s\n' "$MOCK_DOCKER_PS"
    else
      [[ -n "${MOCK_PODMAN_PS:-}" ]] && printf '%s\n' "$MOCK_PODMAN_PS"
    fi
    ;;
  inspect)
    if [[ "$format" == *"RestartCount"* ]]; then
      echo "${MOCK_STATE:-true 0}"
    elif [[ "$format" == "{{.Name}}" ]]; then
      # Existence check. Only the backup container can be missing.
      if [[ "$last" == *.autoops-backup ]]; then
        # It exists when the test says so, or once this run has created it.
        [[ "${MOCK_BACKUP_EXISTS:-}" == "1" ]] && exit 0
        grep -q " rename .* ${last}\$" "$MOCK_LOG" && exit 0
        exit 1
      fi
      echo "/${last}"
    elif [[ "$format" == *"HostConfig.Mounts"* ]]; then
      [[ -n "${MOCK_MOUNTS:-}" ]] && printf '%s\n' "$MOCK_MOUNTS"
    else
      [[ -z "${MOCK_INSPECT:-}" ]] && exit 1
      printf '%s\n' "$MOCK_INSPECT"
    fi
    ;;
  image)
    [[ "${MOCK_IMAGE_MISSING:-}" == "1" ]] && exit 1
    printf '%s\n' "${MOCK_IMAGE_INSPECT:-}"
    ;;
  pull)
    exit "${MOCK_PULL_RC:-0}"
    ;;
  run)
    [[ -n "$env_file" ]] && cp "$env_file" "$MOCK_ENV_COPY"
    exit "${MOCK_RUN_RC:-0}"
    ;;
esac
exit 0
EOF
cp "${MOCK_BIN}/docker" "${MOCK_BIN}/podman"
chmod +x "${MOCK_BIN}/kubectl" "${MOCK_BIN}/docker" "${MOCK_BIN}/podman"

MOCK_VARS=(MOCK_K8S_UNREACHABLE MOCK_K8S_DEPLOYMENTS MOCK_K8S_SET_IMAGE_RC MOCK_K8S_ROLLOUT_RC
  MOCK_K8S_UNDO_RC MOCK_DOCKER_PS MOCK_PODMAN_PS MOCK_STATE MOCK_BACKUP_EXISTS MOCK_MOUNTS
  MOCK_INSPECT MOCK_IMAGE_MISSING MOCK_IMAGE_INSPECT MOCK_PULL_RC MOCK_RUN_RC)

reset_mocks() {
  local var
  for var in "${MOCK_VARS[@]}"; do
    unset "$var"
  done
  : >"$MOCK_LOG"
  rm -f "$MOCK_ENV_COPY"
}

OUTPUT=""
RC=0

# run_upgrade <args...>: runs the script without a terminal, with the mocks first on PATH.
run_upgrade() {
  local var
  for var in "${MOCK_VARS[@]}"; do
    [[ -n "${!var:-}" ]] && export "${var?}"
  done
  export MOCK_LOG MOCK_ENV_COPY
  OUTPUT="$(PATH="${MOCK_BIN}:${PATH}" bash "$UPGRADE_SCRIPT" "$@" </dev/null 2>&1)"
  RC=$?
}

# ---------------------------
# Fixtures
# ---------------------------

# namespace|name|managed-by|ECK type|containers
K8S_PLAIN='default|autoops-elastic-agent|||autoops-elastic-agent=docker.elastic.co/elastic-agent/elastic-otel-collector-wolfi:9.2.0;'
K8S_PRIVATE_REGISTRY='monitoring|autoops-elastic-agent|||autoops-elastic-agent=registry.local:5000/mirror/elastic-otel-collector-wolfi:9.2.0;'
K8S_SIDECAR='default|autoops-elastic-agent|||proxy=envoyproxy/envoy:v1.36.7;agent=docker.elastic.co/elastic-agent/elastic-otel-collector-wolfi:9.2.0;'
K8S_ECK='elastic|policy-es-autoops||autoops-agent|autoops-agent=docker.elastic.co/elastic-agent/elastic-otel-collector-wolfi:9.2.0;'
K8S_HELM='default|agent-autoops-release|Helm||agent=docker.elastic.co/elastic-agent/elastic-otel-collector-wolfi:9.2.0;'
K8S_UNRELATED='default|web|||web=nginx:1.27;'

DOCKER_PS='autoops-agent|docker.elastic.co/elastic-agent/elastic-otel-collector-wolfi:9.2.0'

DOCKER_INSPECT='name=/autoops-agent
image=docker.elastic.co/elastic-agent/elastic-otel-collector-wolfi:9.2.0
imageid=sha256:0123
running=true
user=
restart=unless-stopped
restartmax=0
memory=943718400
memswap=1887436800
nanocpus=500000000
network=bridge
privileged=false
entrypoint=/usr/bin/tini
entrypoint=--
cmd=--config
cmd=otel_samples/autoops_es.yml
env=AUTOOPS_OTEL_URL=https://otel.example
env=AUTOOPS_ES_URL=https://es.example:9200
env=ELASTIC_CLOUD_CONNECTED_MODE_API_KEY=TOP-SECRET-KEY
env=GOMEMLIMIT=720MiB
env=PATH=/usr/local/bin:/usr/bin
env=ELASTIC_CONTAINER=true
bind=/etc/autoops/ca.crt:/ca.crt:ro
addhost=es.example:10.0.0.5
port=127.0.0.1|13133|13133/tcp'

DOCKER_IMAGE_INSPECT='user=
entrypoint=/usr/bin/tini
entrypoint=--
cmd=--help
env=PATH=/usr/local/bin:/usr/bin
env=ELASTIC_CONTAINER=true'

# ---------------------------
# Usage
# ---------------------------

log_test "Unknown parameter is rejected"
run_upgrade --nope
assert_exit_code 2
assert_output_contains "Unknown parameter: --nope"

log_test "Invalid version is rejected"
run_upgrade --version latest
assert_exit_code 2
assert_output_contains "--version must look like"

log_test "Invalid target is rejected"
run_upgrade --target windows
assert_exit_code 2

log_test "A flag without its value is rejected"
run_upgrade --version
assert_exit_code 2
assert_output_contains "--version requires a value"

log_test "--help prints usage"
run_upgrade --help
assert_exit_code 0
assert_output_contains "--dry-run"

log_test "No install found"
MOCK_K8S_DEPLOYMENTS="$K8S_UNRELATED"
run_upgrade --version 9.4.9 --yes
if [[ -f /etc/systemd/system/elastic-agent.service.d/autoops-env.conf ]]; then
  assert_exit_code 3
else
  assert_exit_code 4
  assert_output_contains "No AutoOps agent install was found"
fi
assert_not_called "set image"

# ---------------------------
# Kubernetes
# ---------------------------

log_test "k8s: dry run shows the plan and changes nothing"
MOCK_K8S_DEPLOYMENTS="$K8S_PLAIN"
run_upgrade --version 9.4.9 --dry-run
assert_exit_code 0
assert_output_contains "Image now:  docker.elastic.co/elastic-agent/elastic-otel-collector-wolfi:9.2.0"
assert_output_contains "Image next: docker.elastic.co/elastic-agent/elastic-otel-collector-wolfi:9.4.9"
assert_output_contains "Dry run: nothing was changed."
assert_not_called "set image"
assert_not_called "rollout"

log_test "k8s: upgrade changes only the image and waits for the rollout"
MOCK_K8S_DEPLOYMENTS="$K8S_PLAIN"
run_upgrade --version 9.4.9 --yes
assert_exit_code 0
assert_called "kubectl --namespace default set image deployment/autoops-elastic-agent autoops-elastic-agent=docker.elastic.co/elastic-agent/elastic-otel-collector-wolfi:9.4.9"
assert_called "kubectl --namespace default rollout status deployment/autoops-elastic-agent --timeout 300s"
assert_not_called "rollout undo"
assert_not_called "apply"
assert_output_contains "Upgraded Deployment autoops-elastic-agent to 9.4.9."

log_test "k8s: confirmation is required when there is no terminal"
MOCK_K8S_DEPLOYMENTS="$K8S_PLAIN"
run_upgrade --version 9.4.9
assert_exit_code 2
assert_output_contains "Re-run with --yes"
assert_not_called "set image"

log_test "k8s: a private registry with a port keeps its repository"
MOCK_K8S_DEPLOYMENTS="$K8S_PRIVATE_REGISTRY"
run_upgrade --version 9.4.9 --yes --all-namespaces
assert_exit_code 0
assert_called "kubectl get deployments --all-namespaces"
assert_called "kubectl --namespace monitoring set image deployment/autoops-elastic-agent autoops-elastic-agent=registry.local:5000/mirror/elastic-otel-collector-wolfi:9.4.9"

log_test "k8s: --namespace, --context and --timeout are passed to kubectl"
MOCK_K8S_DEPLOYMENTS="$K8S_PRIVATE_REGISTRY"
run_upgrade --version 9.4.9 --yes --namespace monitoring --context prod --timeout 60
assert_exit_code 0
assert_called "kubectl --context prod get deployments --namespace monitoring"
assert_called "kubectl --context prod --namespace monitoring rollout status deployment/autoops-elastic-agent --timeout 60s"

log_test "k8s: the agent container is picked next to a sidecar"
MOCK_K8S_DEPLOYMENTS="$K8S_SIDECAR"
run_upgrade --version 9.4.9 --yes
assert_exit_code 0
assert_called "set image deployment/autoops-elastic-agent agent=docker.elastic.co/elastic-agent/elastic-otel-collector-wolfi:9.4.9"

log_test "k8s: unrelated Deployments are ignored"
MOCK_K8S_DEPLOYMENTS="${K8S_UNRELATED}
${K8S_PLAIN}"
run_upgrade --version 9.4.9 --yes
assert_exit_code 0
assert_called "set image deployment/autoops-elastic-agent"
assert_not_called "deployment/web"

log_test "k8s: already on the requested version"
MOCK_K8S_DEPLOYMENTS="$K8S_PLAIN"
run_upgrade --version 9.2.0 --yes
assert_exit_code 0
assert_output_contains "already on version 9.2.0"
assert_not_called "set image"

log_test "k8s: a downgrade is refused unless allowed"
MOCK_K8S_DEPLOYMENTS="$K8S_PLAIN"
run_upgrade --version 9.1.5 --yes
assert_exit_code 2
assert_output_contains "--allow-downgrade"
assert_not_called "set image"

log_test "k8s: --allow-downgrade allows an older version"
MOCK_K8S_DEPLOYMENTS="$K8S_PLAIN"
run_upgrade --version 9.1.5 --yes --allow-downgrade
assert_exit_code 0
assert_called "elastic-otel-collector-wolfi:9.1.5"

log_test "k8s: a failed rollout restores the previous version"
MOCK_K8S_DEPLOYMENTS="$K8S_PLAIN"
MOCK_K8S_ROLLOUT_RC=1
run_upgrade --version 9.4.9 --yes
assert_exit_code 1
assert_call_order "set image" "rollout undo deployment/autoops-elastic-agent"
assert_output_contains "is running again"

log_test "k8s: a failed image change is reported"
MOCK_K8S_DEPLOYMENTS="$K8S_PLAIN"
MOCK_K8S_SET_IMAGE_RC=1
run_upgrade --version 9.4.9 --yes
assert_exit_code 1
assert_not_called "rollout"

log_test "k8s: --rollback undoes the last rollout"
MOCK_K8S_DEPLOYMENTS="$K8S_PLAIN"
run_upgrade --rollback --yes
assert_exit_code 0
assert_called "kubectl --namespace default rollout undo deployment/autoops-elastic-agent"
assert_not_called "set image"

log_test "k8s: --rollback --dry-run changes nothing"
MOCK_K8S_DEPLOYMENTS="$K8S_PLAIN"
run_upgrade --rollback --dry-run
assert_exit_code 0
assert_not_called "rollout undo"

log_test "k8s: an ECK-managed agent is not changed"
MOCK_K8S_DEPLOYMENTS="$K8S_ECK"
run_upgrade --version 9.4.9 --yes
assert_exit_code 3
assert_output_contains "managed by ECK"
assert_output_contains '{"spec":{"version":"9.4.9"}}'
assert_not_called "set image"

log_test "k8s: a Helm-managed agent is not changed"
MOCK_K8S_DEPLOYMENTS="$K8S_HELM"
run_upgrade --version 9.4.9 --yes
assert_exit_code 3
assert_output_contains "managed by Helm"
assert_not_called "set image"

log_test "k8s: --target k8s fails when the cluster cannot be queried"
MOCK_K8S_UNREACHABLE=1
run_upgrade --target k8s --version 9.4.9 --yes
assert_exit_code 1
assert_output_contains "could not be queried"

# ---------------------------
# Docker / Podman
# ---------------------------

log_test "docker: dry run shows the plan, hides secrets and changes nothing"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
run_upgrade --version 9.4.9 --dry-run
assert_exit_code 0
assert_output_contains "Image next: docker.elastic.co/elastic-agent/elastic-otel-collector-wolfi:9.4.9"
assert_output_contains "ELASTIC_CLOUD_CONNECTED_MODE_API_KEY"
assert_output_not_contains "TOP-SECRET-KEY"
assert_output_not_contains "https://es.example:9200"
assert_output_contains "Dry run: nothing was changed."
assert_not_called "docker pull"
assert_not_called "docker stop"
assert_not_called "docker run"

log_test "docker: upgrade recreates the container with its settings"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
run_upgrade --version 9.4.9 --yes --settle-seconds 0
assert_exit_code 0
assert_call_order "docker pull docker.elastic.co/elastic-agent/elastic-otel-collector-wolfi:9.4.9" "docker stop autoops-agent"
assert_call_order "docker rename autoops-agent autoops-agent.autoops-backup" "docker run --detach --name autoops-agent"
assert_called "--restart unless-stopped"
assert_called "--memory 943718400 --memory-swap 1887436800"
assert_called "--cpus 0.500"
assert_called "--volume /etc/autoops/ca.crt:/ca.crt:ro"
assert_called "--add-host es.example:10.0.0.5"
assert_called "--publish 127.0.0.1:13133:13133/tcp"
assert_called "elastic-otel-collector-wolfi:9.4.9 --config otel_samples/autoops_es.yml"
assert_not_called "--network"
assert_not_called "--user"
assert_not_called "--privileged"
assert_output_not_contains "TOP-SECRET-KEY"
assert_output_contains "Upgraded container autoops-agent to 9.4.9."

log_test "docker: the environment is kept, without the old image's defaults"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
run_upgrade --version 9.4.9 --yes --settle-seconds 0
EXPECTED_ENV='AUTOOPS_OTEL_URL=https://otel.example
AUTOOPS_ES_URL=https://es.example:9200
ELASTIC_CLOUD_CONNECTED_MODE_API_KEY=TOP-SECRET-KEY
GOMEMLIMIT=720MiB'
if [[ -f "$MOCK_ENV_COPY" && "$(cat "$MOCK_ENV_COPY")" == "$EXPECTED_ENV" ]]; then
  log_pass "Env file has the user's variables and nothing from the image"
else
  log_fail "Env file content is wrong"
  [[ -f "$MOCK_ENV_COPY" ]] && sed 's/=.*/=<hidden>/; s/^/      | /' "$MOCK_ENV_COPY"
fi

log_test "docker: the image's default command is not pinned"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="${DOCKER_INSPECT/cmd=--config
cmd=otel_samples\/autoops_es.yml/cmd=--help}"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
run_upgrade --version 9.4.9 --yes --settle-seconds 0
assert_exit_code 0
assert_not_called "elastic-otel-collector-wolfi:9.4.9 --help"

log_test "docker: --no-pull skips the pull"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
run_upgrade --version 9.4.9 --yes --settle-seconds 0 --no-pull
assert_exit_code 0
assert_not_called "docker pull"
assert_called "docker run"

log_test "docker: a failed pull changes nothing"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
MOCK_PULL_RC=1
run_upgrade --version 9.4.9 --yes --settle-seconds 0
assert_exit_code 1
assert_not_called "docker stop"
assert_not_called "docker rename"

log_test "docker: a container that cannot start is replaced by the previous one"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
MOCK_RUN_RC=125
run_upgrade --version 9.4.9 --yes --settle-seconds 0
assert_exit_code 1
assert_call_order "docker rm --force autoops-agent" "docker rename autoops-agent.autoops-backup autoops-agent"
assert_called "docker start autoops-agent"
assert_output_contains "is back in place"

log_test "docker: a container that does not stay up is replaced by the previous one"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
MOCK_STATE="false 0"
run_upgrade --version 9.4.9 --yes --settle-seconds 0
assert_exit_code 1
assert_call_order "docker run" "docker rename autoops-agent.autoops-backup autoops-agent"
assert_called "docker start autoops-agent"

log_test "docker: a restarting container counts as failed"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
MOCK_STATE="true 3"
run_upgrade --version 9.4.9 --yes --settle-seconds 0
assert_exit_code 1
assert_called "docker rename autoops-agent.autoops-backup autoops-agent"

log_test "docker: an older backup is removed before the new one is made"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
MOCK_BACKUP_EXISTS=1
run_upgrade --version 9.4.9 --yes --settle-seconds 0
assert_exit_code 0
assert_call_order "docker rm autoops-agent.autoops-backup" "docker rename autoops-agent autoops-agent.autoops-backup"

log_test "docker: a custom entrypoint is not upgraded automatically"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="${DOCKER_INSPECT/entrypoint=\/usr\/bin\/tini/entrypoint=/custom/start.sh}"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
run_upgrade --version 9.4.9 --yes --settle-seconds 0
assert_exit_code 3
assert_output_contains "custom --entrypoint"
assert_not_called "docker stop"

log_test "docker: when the old image is gone, every variable is kept"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_MISSING=1
run_upgrade --version 9.4.9 --yes --settle-seconds 0
assert_exit_code 0
assert_output_contains "old image is no longer on this host"
if [[ -f "$MOCK_ENV_COPY" ]] && grep -q '^ELASTIC_CONTAINER=true$' "$MOCK_ENV_COPY"; then
  log_pass "Env file keeps the image's variables too"
else
  log_fail "Env file should keep every variable"
fi

log_test "docker: containers that are not AutoOps agents are ignored"
MOCK_DOCKER_PS='fleet-agent|docker.elastic.co/elastic-agent/elastic-agent:9.2.0'
MOCK_INSPECT="${DOCKER_INSPECT/env=AUTOOPS_OTEL_URL=https:\/\/otel.example/env=FLEET_URL=https://fleet.example}"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
run_upgrade --target docker --version 9.4.9 --yes --settle-seconds 0
assert_exit_code 4
assert_not_called "docker stop"

log_test "docker: --container picks a container by name"
MOCK_DOCKER_PS='my-agent|registry.local:5000/mirror/collector:9.2.0'
MOCK_INSPECT="${DOCKER_INSPECT//docker.elastic.co\/elastic-agent\/elastic-otel-collector-wolfi/registry.local:5000/mirror/collector}"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
run_upgrade --target docker --container my-agent --version 9.4.9 --yes --settle-seconds 0
assert_exit_code 0
assert_called "docker run --detach --name my-agent"
assert_called "registry.local:5000/mirror/collector:9.4.9"

log_test "docker: --rollback restores the backup container"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_BACKUP_EXISTS=1
run_upgrade --rollback --yes
assert_exit_code 0
assert_call_order "docker rm autoops-agent" "docker rename autoops-agent.autoops-backup autoops-agent"
assert_called "docker start autoops-agent"
assert_not_called "docker run"

log_test "docker: --rollback without a backup fails and changes nothing"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
run_upgrade --rollback --yes
assert_exit_code 1
assert_output_contains "nothing to roll back to"
assert_not_called "docker rm"

log_test "podman: a Podman container is upgraded with podman"
MOCK_PODMAN_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
run_upgrade --version 9.4.9 --yes --settle-seconds 0
assert_exit_code 0
assert_called "podman run --detach --name autoops-agent"
assert_not_called "docker run"

# ---------------------------
# Several installs
# ---------------------------

log_test "More than one install asks the user to choose"
MOCK_K8S_DEPLOYMENTS="$K8S_PLAIN"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
run_upgrade --version 9.4.9 --yes
assert_exit_code 2
assert_output_contains "More than one AutoOps agent install was found"
assert_output_contains "--target k8s --namespace default --deployment autoops-elastic-agent"
assert_output_contains "--target docker --container autoops-agent"
assert_not_called "set image"
assert_not_called "docker stop"

log_test "--target limits the search to one install type"
MOCK_K8S_DEPLOYMENTS="$K8S_PLAIN"
MOCK_DOCKER_PS="$DOCKER_PS"
MOCK_INSPECT="$DOCKER_INSPECT"
MOCK_IMAGE_INSPECT="$DOCKER_IMAGE_INSPECT"
run_upgrade --target k8s --version 9.4.9 --yes
assert_exit_code 0
assert_called "set image"
assert_not_called "docker ps"

# ---------------------------
# Summary
# ---------------------------

echo ""
echo "=============================="
echo "Tests passed: ${TESTS_PASSED}"
echo "Tests failed: ${TESTS_FAILED}"
echo "=============================="

if [[ "$TESTS_FAILED" -gt 0 ]]; then
  exit 1
fi
