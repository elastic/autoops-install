#!/bin/bash
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License
# 2.0; you may not use this file except in compliance with the Elastic License
# 2.0.
#

# Upgrades an installed AutoOps agent in place, keeping its credentials and
# settings. Supported install types:
#
#   - Kubernetes Deployment created from k8s/autoops_agent_deployment.yaml
#   - Docker / Podman container
#
# Helm, ECK and Linux service installs are detected, and the script prints what
# to do for them without changing anything.
#
# Usage examples:
#   ./upgrade_autoops.sh --dry-run
#   ./upgrade_autoops.sh --version 9.4.9
#   ./upgrade_autoops.sh --target k8s --namespace monitoring --yes
#   ./upgrade_autoops.sh --target docker --container autoops-agent --rollback
#
# The script never prints secret values. Environment variables are shown by
# name only.

set -uo pipefail

# ---------------------------
# Configurable defaults
# ---------------------------
DEFAULT_VERSION="9.4.9"
DEFAULT_K8S_DEPLOYMENT="autoops-elastic-agent"
BACKUP_SUFFIX=".autoops-backup"

VERSION="$DEFAULT_VERSION"
TARGET="auto"          # auto | k8s | docker | podman
DRY_RUN=false
ROLLBACK=false
ASSUME_YES=false
ALLOW_DOWNGRADE=false
PULL=true
TIMEOUT_SECONDS=300    # k8s rollout timeout
SETTLE_SECONDS=20      # how long a new container must stay up

K8S_NAMESPACE=""
K8S_ALL_NAMESPACES=false
K8S_CONTEXT=""
K8S_DEPLOYMENT=""
K8S_CONTAINER=""

CONTAINER=""

# Exit codes
EXIT_OK=0
EXIT_FAILED=1
EXIT_USAGE=2
EXIT_MANUAL=3          # an install was found, but this script does not upgrade that type
EXIT_NOT_FOUND=4

# ---------------------------
# Helpers
# ---------------------------
log()  { echo "$*"; }
warn() { echo "Warning: $*" >&2; }
err()  { echo "Error: $*" >&2; }

usage() {
  cat <<EOF
Usage: $0 [options]

Upgrades an installed AutoOps agent in place, keeping credentials and settings.

General:
  --version <x.y.z>       Version to upgrade to (default: ${DEFAULT_VERSION})
  --target <type>         auto | k8s | docker | podman (default: auto)
  --dry-run               Show what would change and exit. Changes nothing.
  --rollback              Go back to the version that ran before the last upgrade
  --yes                   Do not ask for confirmation
  --allow-downgrade       Allow --version to be older than the installed version
  -h, --help              Show this help

Kubernetes:
  --namespace <ns>        Namespace of the agent Deployment (default: current namespace)
  --all-namespaces        Look for the agent Deployment in every namespace
  --context <name>        kubectl context to use
  --deployment <name>     Deployment name (default: ${DEFAULT_K8S_DEPLOYMENT}, or detected)
  --k8s-container <name>  Container name inside the Deployment (default: detected)
  --timeout <seconds>     How long to wait for the rollout (default: ${TIMEOUT_SECONDS})

Docker / Podman:
  --container <name>      Container name or ID (default: detected)
  --no-pull               Do not pull the new image (it is already on this host)
  --settle-seconds <n>    How long the new container must stay up (default: ${SETTLE_SECONDS})

Exit codes:
  0  upgraded, rolled back, or nothing to do
  1  the upgrade failed (the previous version was restored when possible)
  2  wrong usage
  3  an install was found that this script does not upgrade (Helm, ECK, Linux service)
  4  no AutoOps agent install was found
EOF
}

need_value() {
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    err "$1 requires a value"
    exit "$EXIT_USAGE"
  fi
}

# split_image <image ref>: sets IMG_REPO and IMG_TAG (empty when there is no tag).
split_image() {
  local ref="$1" last
  ref="${ref%%@*}" # drop a digest, if any
  last="${ref##*/}"
  if [[ "$last" == *:* ]]; then
    IMG_REPO="${ref%:*}"
    IMG_TAG="${last##*:}"
  else
    IMG_REPO="$ref"
    IMG_TAG=""
  fi
}

# version_lt <a> <b>: true when a is older than b.
version_lt() {
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

# check_version_change <current tag>: exits when there is nothing to do or the
# change is a downgrade that was not asked for.
check_version_change() {
  local current="$1"
  if [[ -z "$current" ]]; then
    warn "The installed image has no version tag, so the installed version is unknown."
    return 0
  fi
  if [[ "$current" == "$VERSION" ]]; then
    log "The agent is already on version ${VERSION}. Nothing to do."
    exit "$EXIT_OK"
  fi
  if version_lt "$VERSION" "$current" && [[ "$ALLOW_DOWNGRADE" == false ]]; then
    err "Version ${VERSION} is older than the installed version ${current}. Use --allow-downgrade to do this anyway."
    exit "$EXIT_USAGE"
  fi
}

confirm() {
  local answer
  if [[ "$ASSUME_YES" == true ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    err "Confirmation is needed, but there is no terminal to ask on. Re-run with --yes to proceed."
    exit "$EXIT_USAGE"
  fi
  read -r -p "$1 [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) log "Cancelled. Nothing was changed."; exit "$EXIT_OK" ;;
  esac
}

# ---------------------------
# Parse args
# ---------------------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) need_value "$@"; VERSION="$2"; shift 2;;
    --target) need_value "$@"; TARGET="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --rollback) ROLLBACK=true; shift;;
    --yes|-y) ASSUME_YES=true; shift;;
    --allow-downgrade) ALLOW_DOWNGRADE=true; shift;;
    --namespace|-n) need_value "$@"; K8S_NAMESPACE="$2"; shift 2;;
    --all-namespaces) K8S_ALL_NAMESPACES=true; shift;;
    --context) need_value "$@"; K8S_CONTEXT="$2"; shift 2;;
    --deployment) need_value "$@"; K8S_DEPLOYMENT="$2"; shift 2;;
    --k8s-container) need_value "$@"; K8S_CONTAINER="$2"; shift 2;;
    --timeout) need_value "$@"; TIMEOUT_SECONDS="$2"; shift 2;;
    --container) need_value "$@"; CONTAINER="$2"; shift 2;;
    --no-pull) PULL=false; shift;;
    --settle-seconds) need_value "$@"; SETTLE_SECONDS="$2"; shift 2;;
    -h|--help) usage; exit "$EXIT_OK";;
    *) err "Unknown parameter: $1"; usage >&2; exit "$EXIT_USAGE";;
  esac
done

# ---------------------------
# Validate inputs
# ---------------------------
case "$TARGET" in
  auto|k8s|docker|podman) ;;
  *) err "--target must be one of: auto, k8s, docker, podman"; exit "$EXIT_USAGE";;
esac

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-SNAPSHOT)?$ ]]; then
  err "--version must look like 9.4.9 (got '${VERSION}')"
  exit "$EXIT_USAGE"
fi

if [[ ! "$TIMEOUT_SECONDS" =~ ^[0-9]+$ || ! "$SETTLE_SECONDS" =~ ^[0-9]+$ ]]; then
  err "--timeout and --settle-seconds must be whole numbers of seconds"
  exit "$EXIT_USAGE"
fi

if [[ -n "$K8S_NAMESPACE" && "$K8S_ALL_NAMESPACES" == true ]]; then
  err "--namespace cannot be combined with --all-namespaces"
  exit "$EXIT_USAGE"
fi

# ---------------------------
# Kubernetes
# ---------------------------
KUBECTL=(kubectl)

# One line per Deployment: namespace|name|managed-by|ECK type|name=image;name=image;
K8S_LIST_TEMPLATE='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"|"}{.metadata.labels.common\.k8s\.elastic\.co/type}{"|"}{range .spec.template.spec.containers[*]}{.name}{"="}{.image}{";"}{end}{"\n"}{end}'

K8S_FOUND=()    # candidate lines, same format as the template

k8s_available() {
  command -v kubectl >/dev/null 2>&1
}

# k8s_find: fills K8S_FOUND. Returns 1 when the cluster cannot be queried.
k8s_find() {
  local scope=() listing line ns name managed type containers
  K8S_FOUND=()

  if [[ -n "$K8S_CONTEXT" ]]; then
    KUBECTL=(kubectl --context "$K8S_CONTEXT")
  fi
  if [[ "$K8S_ALL_NAMESPACES" == true ]]; then
    scope=(--all-namespaces)
  elif [[ -n "$K8S_NAMESPACE" ]]; then
    scope=(--namespace "$K8S_NAMESPACE")
  fi

  if ! listing="$("${KUBECTL[@]}" get deployments ${scope[@]+"${scope[@]}"} --request-timeout=15s -o "jsonpath=${K8S_LIST_TEMPLATE}" 2>/dev/null)"; then
    return 1
  fi

  while IFS='|' read -r ns name managed type containers; do
    [[ -z "$name" ]] && continue
    if [[ -n "$K8S_DEPLOYMENT" ]]; then
      [[ "$name" == "$K8S_DEPLOYMENT" ]] || continue
    elif [[ "$name" != "$DEFAULT_K8S_DEPLOYMENT" && "$type" != "autoops-agent" && "$containers" != *elastic-otel-collector* ]]; then
      continue
    fi
    K8S_FOUND+=("${ns}|${name}|${managed}|${type}|${containers}")
  done <<<"$listing"
  return 0
}

# k8s_pick_container <containers field>: sets K8S_PICKED_NAME and K8S_PICKED_IMAGE.
k8s_pick_container() {
  local containers="$1" entry name image count=0 first_name="" first_image=""
  K8S_PICKED_NAME=""
  K8S_PICKED_IMAGE=""

  while IFS= read -r -d ';' entry; do
    [[ -z "$entry" ]] && continue
    name="${entry%%=*}"
    image="${entry#*=}"
    count=$((count + 1))
    if [[ $count -eq 1 ]]; then
      first_name="$name"
      first_image="$image"
    fi
    if [[ -n "$K8S_CONTAINER" ]]; then
      if [[ "$name" == "$K8S_CONTAINER" ]]; then
        K8S_PICKED_NAME="$name"; K8S_PICKED_IMAGE="$image"
        return 0
      fi
    elif [[ -z "$K8S_PICKED_NAME" && ( "$image" == *elastic-otel-collector* || "$image" == *elastic-agent* ) ]]; then
      K8S_PICKED_NAME="$name"; K8S_PICKED_IMAGE="$image"
    fi
  done <<<"$containers"

  if [[ -z "$K8S_PICKED_NAME" && -z "$K8S_CONTAINER" && $count -eq 1 ]]; then
    K8S_PICKED_NAME="$first_name"; K8S_PICKED_IMAGE="$first_image"
  fi
  [[ -n "$K8S_PICKED_NAME" ]]
}

k8s_run() {
  local line="$1" ns name managed type containers new_image
  IFS='|' read -r ns name managed type containers <<<"$line"

  log "Found a Kubernetes Deployment: ${name} (namespace ${ns})"

  if [[ "$type" == "autoops-agent" ]]; then
    log ""
    log "This Deployment is managed by ECK (AutoOpsAgentPolicy). Do not change it directly:"
    log "the operator would revert the change. Set the version on the policy instead:"
    log ""
    log "  kubectl get autoopsagentpolicies --all-namespaces"
    log "  kubectl patch autoopsagentpolicy <policy-name> --namespace <policy-namespace> --type merge -p '{\"spec\":{\"version\":\"${VERSION}\"}}'"
    exit "$EXIT_MANUAL"
  fi

  if [[ "$managed" == "Helm" ]]; then
    log ""
    log "This Deployment is managed by Helm. Upgrade it with Helm, so the release stays in sync:"
    log ""
    log "  helm list --namespace ${ns}"
    log "  helm upgrade <release> <chart> --namespace ${ns} --reuse-values --version <chart version for ${VERSION}>"
    exit "$EXIT_MANUAL"
  fi

  if [[ "$ROLLBACK" == true ]]; then
    log ""
    log "Plan: roll Deployment ${name} back to its previous revision (kubectl rollout undo)."
    if [[ "$DRY_RUN" == true ]]; then
      log "Dry run: nothing was changed."
      exit "$EXIT_OK"
    fi
    confirm "Roll back Deployment ${name} in namespace ${ns}?"
    if ! "${KUBECTL[@]}" --namespace "$ns" rollout undo "deployment/${name}"; then
      err "The rollback could not be started."
      exit "$EXIT_FAILED"
    fi
    if ! "${KUBECTL[@]}" --namespace "$ns" rollout status "deployment/${name}" --timeout "${TIMEOUT_SECONDS}s"; then
      err "The rollback did not finish within ${TIMEOUT_SECONDS}s. Check: kubectl --namespace ${ns} describe deployment ${name}"
      exit "$EXIT_FAILED"
    fi
    log "Rolled back."
    exit "$EXIT_OK"
  fi

  if ! k8s_pick_container "$containers"; then
    err "Could not tell which container in Deployment ${name} runs the agent. Pass --k8s-container <name>."
    exit "$EXIT_USAGE"
  fi

  split_image "$K8S_PICKED_IMAGE"
  check_version_change "$IMG_TAG"
  new_image="${IMG_REPO}:${VERSION}"

  log ""
  log "Plan:"
  log "  Container:  ${K8S_PICKED_NAME}"
  log "  Image now:  ${K8S_PICKED_IMAGE}"
  log "  Image next: ${new_image}"
  log "  Kept as is: the Secret, environment variables, resources, volumes and every other setting."
  log "  Only the image of this one container changes; the manifest is not re-applied."
  log "  If the new version does not become ready within ${TIMEOUT_SECONDS}s, the previous one is restored."

  if [[ "$DRY_RUN" == true ]]; then
    log ""
    log "Dry run: nothing was changed."
    exit "$EXIT_OK"
  fi

  confirm "Upgrade Deployment ${name} in namespace ${ns} to ${VERSION}?"

  if ! "${KUBECTL[@]}" --namespace "$ns" set image "deployment/${name}" "${K8S_PICKED_NAME}=${new_image}"; then
    err "The image could not be changed. Nothing was upgraded."
    exit "$EXIT_FAILED"
  fi

  if ! "${KUBECTL[@]}" --namespace "$ns" rollout status "deployment/${name}" --timeout "${TIMEOUT_SECONDS}s"; then
    err "The new version did not become ready within ${TIMEOUT_SECONDS}s. Restoring the previous version..."
    if "${KUBECTL[@]}" --namespace "$ns" rollout undo "deployment/${name}" \
      && "${KUBECTL[@]}" --namespace "$ns" rollout status "deployment/${name}" --timeout "${TIMEOUT_SECONDS}s"; then
      err "The previous version (${K8S_PICKED_IMAGE}) is running again."
    else
      err "The previous version could not be restored automatically. Check: kubectl --namespace ${ns} describe deployment ${name}"
    fi
    exit "$EXIT_FAILED"
  fi

  log ""
  log "Upgraded Deployment ${name} to ${VERSION}."
  log "Logs:     kubectl --namespace ${ns} logs deployment/${name} --container ${K8S_PICKED_NAME} --tail 50"
  log "Rollback: $0 --target k8s --namespace ${ns} --deployment ${name} --rollback"
  exit "$EXIT_OK"
}

# ---------------------------
# Docker / Podman
# ---------------------------
RUNTIME=""

# One "key=value" line per setting. Lists repeat the key.
CONTAINER_TEMPLATE_HEAD='name={{.Name}}{{println}}image={{.Config.Image}}{{println}}imageid={{.Image}}{{println}}running={{.State.Running}}{{println}}user={{.Config.User}}{{println}}restart={{.HostConfig.RestartPolicy.Name}}{{println}}restartmax={{.HostConfig.RestartPolicy.MaximumRetryCount}}{{println}}memory={{.HostConfig.Memory}}{{println}}memswap={{.HostConfig.MemorySwap}}{{println}}nanocpus={{.HostConfig.NanoCpus}}{{println}}network={{.HostConfig.NetworkMode}}{{println}}privileged={{.HostConfig.Privileged}}{{println}}{{range .Config.Entrypoint}}entrypoint={{println .}}{{end}}{{range .Config.Cmd}}cmd={{println .}}{{end}}{{range .Config.Env}}env={{println .}}{{end}}{{range .HostConfig.Binds}}bind={{println .}}{{end}}{{range .HostConfig.ExtraHosts}}addhost={{println .}}{{end}}{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}port={{.HostIp}}|{{.HostPort}}|{{$p}}{{println}}{{end}}{{end}}'
CONTAINER_TEMPLATE_MOUNTS='{{range .HostConfig.Mounts}}mount={{.Type}},{{.Source}},{{.Target}},{{.ReadOnly}}{{println}}{{end}}'
IMAGE_TEMPLATE='user={{.Config.User}}{{println}}{{range .Config.Entrypoint}}entrypoint={{println .}}{{end}}{{range .Config.Cmd}}cmd={{println .}}{{end}}{{range .Config.Env}}env={{println .}}{{end}}'
STATE_TEMPLATE='{{.State.Running}} {{.RestartCount}}'

RUNTIME_FOUND=() # "runtime|container name" for each AutoOps container found

# field <inspect output> <key>: prints every value of that key, one per line.
field() {
  local line key="$2"
  while IFS= read -r line; do
    if [[ "$line" == "${key}="* ]]; then
      printf '%s\n' "${line#"${key}"=}"
    fi
  done <<<"$1"
}

# first_field <inspect output> <key>: prints the first value of that key.
first_field() {
  field "$1" "$2" | head -n 1
}

container_inspect() {
  local runtime="$1" name="$2" out mounts
  if ! out="$("$runtime" inspect --type container --format "$CONTAINER_TEMPLATE_HEAD" "$name" 2>/dev/null)"; then
    return 1
  fi
  # Not every runtime version has HostConfig.Mounts, so read it separately.
  mounts="$("$runtime" inspect --type container --format "$CONTAINER_TEMPLATE_MOUNTS" "$name" 2>/dev/null || true)"
  printf '%s\n%s\n' "$out" "$mounts"
}

# runtime_find <runtime>: adds the AutoOps containers of that runtime to RUNTIME_FOUND.
runtime_find() {
  local runtime="$1" listing name image info
  command -v "$runtime" >/dev/null 2>&1 || return 0
  listing="$("$runtime" ps --all --format '{{.Names}}|{{.Image}}' 2>/dev/null)" || return 0

  while IFS='|' read -r name image; do
    [[ -z "$name" ]] && continue
    [[ "$name" == *"$BACKUP_SUFFIX" ]] && continue
    if [[ -n "$CONTAINER" ]]; then
      [[ "$name" == "$CONTAINER" ]] || continue
    elif [[ "$image" != *elastic-otel-collector* && "$image" != *elastic-agent* ]]; then
      continue
    fi
    # An AutoOps agent always has the AutoOps endpoint in its environment.
    info="$(container_inspect "$runtime" "$name")" || continue
    # (No pipe here: with pipefail, grep -q closing the pipe early would look like a failure.)
    if [[ -z "$CONTAINER" ]] && ! grep -q '^AUTOOPS_OTEL_URL=' <<<"$(field "$info" env)"; then
      continue
    fi
    RUNTIME_FOUND+=("${runtime}|${name}")
  done <<<"$listing"
}

container_exists() {
  "$RUNTIME" inspect --type container --format '{{.Name}}' "$1" >/dev/null 2>&1
}

# container_healthy <name>: waits SETTLE_SECONDS and checks the container stayed up.
container_healthy() {
  local name="$1" waited=0 state
  while :; do
    state="$("$RUNTIME" inspect --type container --format "$STATE_TEMPLATE" "$name" 2>/dev/null)" || return 1
    [[ "$state" == "true 0" ]] || return 1
    [[ $waited -ge $SETTLE_SECONDS ]] && return 0
    sleep 2
    waited=$((waited + 2))
  done
}

# print_command <args...>: prints a command line, hiding the env file path.
print_command() {
  local arg out=""
  for arg in "$@"; do
    if [[ "$arg" == "$ENV_FILE" && -n "$ENV_FILE" ]]; then
      out+=" <file with the ${ENV_COUNT} kept environment variables>"
    else
      out+=" $(printf '%q' "$arg")"
    fi
  done
  log " ${out}"
}

ENV_FILE=""
ENV_COUNT=0
WORK_DIR=""

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

runtime_rollback() {
  local name="$1" backup="${1}${BACKUP_SUFFIX}"

  if ! container_exists "$backup"; then
    err "There is no backup container (${backup}), so there is nothing to roll back to."
    exit "$EXIT_FAILED"
  fi

  log ""
  log "Plan: remove container ${name} and start the backup ${backup} under the name ${name} again."
  if [[ "$DRY_RUN" == true ]]; then
    log "Dry run: nothing was changed."
    exit "$EXIT_OK"
  fi
  confirm "Roll back container ${name}?"

  "$RUNTIME" stop "$name" >/dev/null 2>&1 || true
  if ! "$RUNTIME" rm "$name" >/dev/null; then
    err "Container ${name} could not be removed. Nothing else was changed."
    exit "$EXIT_FAILED"
  fi
  if ! "$RUNTIME" rename "$backup" "$name" || ! "$RUNTIME" start "$name" >/dev/null; then
    err "The backup could not be started. Check: ${RUNTIME} ps --all"
    exit "$EXIT_FAILED"
  fi
  log "Rolled back. Container ${name} runs the previous version again."
  exit "$EXIT_OK"
}

runtime_run() {
  local name="$1" info image_info old_image new_image backup was_running value
  local run_args=() cmd_args=() host_ip host_port container_port
  local type source target readonly mount

  RUNTIME="$2"
  name="${name#/}"
  backup="${name}${BACKUP_SUFFIX}"

  log "Found a ${RUNTIME} container: ${name}"

  if [[ "$ROLLBACK" == true ]]; then
    runtime_rollback "$name"
  fi

  if ! info="$(container_inspect "$RUNTIME" "$name")"; then
    err "Container ${name} could not be inspected."
    exit "$EXIT_FAILED"
  fi

  old_image="$(first_field "$info" image)"
  was_running="$(first_field "$info" running)"
  split_image "$old_image"
  check_version_change "$IMG_TAG"
  new_image="${IMG_REPO}:${VERSION}"

  # Settings that came from the old image must not be copied to the new
  # container, or they would override the new image's own defaults.
  image_info="$("$RUNTIME" image inspect --format "$IMAGE_TEMPLATE" "$(first_field "$info" imageid)" 2>/dev/null || true)"
  if [[ -z "$image_info" ]]; then
    warn "The old image is no longer on this host, so its default settings cannot be told apart from yours."
    warn "All environment variables of the container are kept, including the ones the old image set."
  fi

  if [[ "$(field "$info" entrypoint)" != "$(field "$image_info" entrypoint)" && -n "$image_info" ]]; then
    err "Container ${name} was started with a custom --entrypoint, which this script does not carry over."
    err "Upgrade it by hand: run your original command with image ${new_image}."
    exit "$EXIT_MANUAL"
  fi

  # --- Environment (kept in a private file, never printed) ---
  WORK_DIR="$(mktemp -d)"
  chmod 700 "$WORK_DIR"
  ENV_FILE="${WORK_DIR}/env"
  (umask 077 && : >"$ENV_FILE")
  local image_env env_names=""
  image_env="$(field "$image_info" env)"
  while IFS= read -r value; do
    [[ -z "$value" ]] && continue
    if [[ -n "$image_env" ]] && grep -Fxq -- "$value" <<<"$image_env"; then
      continue
    fi
    printf '%s\n' "$value" >>"$ENV_FILE"
    env_names+="${value%%=*} "
    ENV_COUNT=$((ENV_COUNT + 1))
  done <<<"$(field "$info" env)"

  run_args=(run --detach --name "$name" --env-file "$ENV_FILE")

  # --- Restart policy ---
  value="$(first_field "$info" restart)"
  if [[ -n "$value" && "$value" != "no" ]]; then
    if [[ "$value" == "on-failure" && "$(first_field "$info" restartmax)" != "0" ]]; then
      value="${value}:$(first_field "$info" restartmax)"
    fi
    run_args+=(--restart "$value")
  fi

  # --- Memory and CPU ---
  value="$(first_field "$info" memory)"
  if [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]]; then
    run_args+=(--memory "$value")
    value="$(first_field "$info" memswap)"
    if [[ "$value" =~ ^-?[0-9]+$ && "$value" -ne 0 ]]; then
      run_args+=(--memory-swap "$value")
    fi
  fi
  value="$(first_field "$info" nanocpus)"
  if [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]]; then
    run_args+=(--cpus "$(awk -v n="$value" 'BEGIN { printf "%.3f", n / 1000000000 }')")
  fi

  # --- Network, user, privileges ---
  value="$(first_field "$info" network)"
  if [[ -n "$value" && "$value" != "default" && "$value" != "bridge" ]]; then
    run_args+=(--network "$value")
  fi
  value="$(first_field "$info" user)"
  if [[ -n "$value" && "$value" != "$(first_field "$image_info" user)" ]]; then
    run_args+=(--user "$value")
  fi
  if [[ "$(first_field "$info" privileged)" == "true" ]]; then
    run_args+=(--privileged)
  fi

  # --- Volumes, hosts, ports ---
  while IFS= read -r value; do
    [[ -n "$value" ]] && run_args+=(--volume "$value")
  done <<<"$(field "$info" bind)"
  while IFS=',' read -r type source target readonly; do
    [[ -z "$type" ]] && continue
    mount="type=${type},target=${target}"
    [[ -n "$source" ]] && mount+=",source=${source}"
    [[ "$readonly" == "true" ]] && mount+=",readonly"
    run_args+=(--mount "$mount")
  done <<<"$(field "$info" mount)"
  while IFS= read -r value; do
    [[ -n "$value" ]] && run_args+=(--add-host "$value")
  done <<<"$(field "$info" addhost)"
  while IFS='|' read -r host_ip host_port container_port; do
    [[ -z "$container_port" ]] && continue
    if [[ -n "$host_ip" && "$host_ip" != "0.0.0.0" ]]; then
      run_args+=(--publish "${host_ip}:${host_port}:${container_port}")
    else
      run_args+=(--publish "${host_port}:${container_port}")
    fi
  done <<<"$(field "$info" port)"

  # --- Command (only when it is not the old image's default) ---
  if [[ -z "$image_info" || "$(field "$info" cmd)" != "$(field "$image_info" cmd)" ]]; then
    while IFS= read -r value; do
      [[ -n "$value" ]] && cmd_args+=("$value")
    done <<<"$(field "$info" cmd)"
  fi

  run_args+=("$new_image")
  run_args+=(${cmd_args[@]+"${cmd_args[@]}"})

  log ""
  log "Plan:"
  log "  Image now:  ${old_image}"
  log "  Image next: ${new_image}"
  log "  Kept environment variables (${ENV_COUNT}, values not shown): ${env_names:-none}"
  log "  The current container is stopped and kept as ${backup}, so it can be restored."
  if container_exists "$backup"; then
    log "  An older backup container named ${backup} exists and will be removed first."
  fi
  log "  The new container is started with:"
  print_command "$RUNTIME" "${run_args[@]}"
  log "  Carried over: environment, command, restart policy, memory and CPU limits, network,"
  log "  user, --privileged, volumes, --add-host and published ports. Other options are not."
  log "  If the new container does not stay up for ${SETTLE_SECONDS}s, the previous one is restored."

  if [[ "$DRY_RUN" == true ]]; then
    log ""
    log "Dry run: nothing was changed."
    exit "$EXIT_OK"
  fi

  confirm "Upgrade container ${name} to ${VERSION}?"

  if [[ "$PULL" == true ]]; then
    log "Pulling ${new_image}..."
    if ! "$RUNTIME" pull "$new_image"; then
      err "The image ${new_image} could not be pulled. Nothing was changed."
      exit "$EXIT_FAILED"
    fi
  fi

  if container_exists "$backup"; then
    if ! "$RUNTIME" rm "$backup" >/dev/null; then
      err "The older backup container ${backup} could not be removed. Nothing was changed."
      exit "$EXIT_FAILED"
    fi
  fi

  "$RUNTIME" stop "$name" >/dev/null 2>&1 || true
  if ! "$RUNTIME" rename "$name" "$backup"; then
    err "Container ${name} could not be renamed."
    [[ "$was_running" == "true" ]] && "$RUNTIME" start "$name" >/dev/null 2>&1
    exit "$EXIT_FAILED"
  fi

  if "$RUNTIME" "${run_args[@]}" >/dev/null && container_healthy "$name"; then
    log ""
    log "Upgraded container ${name} to ${VERSION}."
    log "Logs:          ${RUNTIME} logs --tail 50 ${name}"
    log "Rollback:      $0 --target ${RUNTIME} --container ${name} --rollback"
    log "Remove backup: ${RUNTIME} rm ${backup}"
    exit "$EXIT_OK"
  fi

  err "The new container did not stay up. Restoring the previous one..."
  "$RUNTIME" logs --tail 20 "$name" 2>&1 | sed 's/^/  | /' >&2 || true
  "$RUNTIME" rm --force "$name" >/dev/null 2>&1 || true
  if "$RUNTIME" rename "$backup" "$name"; then
    if [[ "$was_running" != "true" ]] || "$RUNTIME" start "$name" >/dev/null; then
      err "The previous version (${old_image}) is back in place."
      exit "$EXIT_FAILED"
    fi
  fi
  err "The previous container could not be restored automatically. It is kept as ${backup}."
  exit "$EXIT_FAILED"
}

# ---------------------------
# Linux service (detected only)
# ---------------------------
linux_service_installed() {
  [[ -f /etc/systemd/system/elastic-agent.service.d/autoops-env.conf ]]
}

# ---------------------------
# Detect and dispatch
# ---------------------------
FOUND_SUMMARY=()

if [[ "$TARGET" == "auto" || "$TARGET" == "k8s" ]]; then
  if k8s_available; then
    if ! k8s_find && [[ "$TARGET" == "k8s" ]]; then
      err "The Kubernetes cluster could not be queried. Check your kubectl context and permissions."
      exit "$EXIT_FAILED"
    fi
    for entry in ${K8S_FOUND[@]+"${K8S_FOUND[@]}"}; do
      IFS='|' read -r found_ns found_name _ <<<"$entry"
      FOUND_SUMMARY+=("k8s: deployment ${found_name} in namespace ${found_ns}  (--target k8s --namespace ${found_ns} --deployment ${found_name})")
    done
  elif [[ "$TARGET" == "k8s" ]]; then
    err "kubectl was not found on this machine."
    exit "$EXIT_FAILED"
  fi
fi

if [[ "$TARGET" == "auto" || "$TARGET" == "docker" ]]; then
  runtime_find docker
fi
if [[ "$TARGET" == "auto" || "$TARGET" == "podman" ]]; then
  runtime_find podman
fi
if [[ "$TARGET" == "docker" || "$TARGET" == "podman" ]] && ! command -v "$TARGET" >/dev/null 2>&1; then
  err "${TARGET} was not found on this machine."
  exit "$EXIT_FAILED"
fi
for entry in ${RUNTIME_FOUND[@]+"${RUNTIME_FOUND[@]}"}; do
  FOUND_SUMMARY+=("${entry%%|*}: container ${entry#*|}  (--target ${entry%%|*} --container ${entry#*|})")
done

if [[ ${#FOUND_SUMMARY[@]} -eq 0 ]]; then
  if [[ "$TARGET" == "auto" ]] && linux_service_installed; then
    log "Found a Linux service install (elastic-agent systemd service)."
    log "This script does not upgrade Linux service installs yet."
    log "For now, re-run linux/install_autoops.sh with the new --version and your original parameters."
    exit "$EXIT_MANUAL"
  fi
  err "No AutoOps agent install was found."
  err "Kubernetes: pass --namespace (or --all-namespaces) and, if you renamed it, --deployment."
  err "Docker / Podman: pass --container <name>."
  exit "$EXIT_NOT_FOUND"
fi

if [[ ${#FOUND_SUMMARY[@]} -gt 1 ]]; then
  err "More than one AutoOps agent install was found. Choose one and re-run with its options:"
  for entry in "${FOUND_SUMMARY[@]}"; do
    err "  ${entry}"
  done
  exit "$EXIT_USAGE"
fi

if [[ ${#K8S_FOUND[@]} -eq 1 ]]; then
  k8s_run "${K8S_FOUND[0]}"
else
  runtime_run "${RUNTIME_FOUND[0]#*|}" "${RUNTIME_FOUND[0]%%|*}"
fi
