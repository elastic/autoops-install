#!/bin/bash
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License
# 2.0; you may not use this file except in compliance with the Elastic License
# 2.0.
#

# Usage example:
# ./check_connectivity.sh
# ./check_connectivity.sh --debug
#
# Environment variables:
#   ELASTIC_CLOUD_CONNECTED_MODE_API_URL - Cloud API URL (default: https://api.elastic-cloud.com)
#   AUTOOPS_OTEL_URL                     - OTel endpoint URL (default: https://otel-auto-ops.ap-northeast-1.aws.svc.elastic.cloud)
#   AUTOOPS_ES_URL                       - Elasticsearch URL (optional)
#   AUTOOPS_ES_USERNAME                  - Elasticsearch username (for Basic auth)
#   AUTOOPS_ES_PASSWORD                  - Elasticsearch password (for Basic auth)
#   AUTOOPS_ES_API_KEY                   - Elasticsearch API key (for ApiKey auth)
#   AUTOOPS_ES_CA                        - Path to CA certificate file (optional)

# ---------------------------
# Dependency check
# ---------------------------

if ! command -v curl &> /dev/null; then
  echo "❌ FAIL: 'curl' is required but not installed."
  exit 1
fi

# ---------------------------
# Argument parsing
# ---------------------------

DEBUG=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      DEBUG=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--debug]"
      exit 1
      ;;
  esac
done

# ---------------------------
# Output formatting functions
# ---------------------------

print_header() {
  echo ""
  echo "========================================"
  echo "  AutoOps Connectivity Check"
  echo "========================================"
  echo ""
}

print_section() {
  echo ""
  echo "--- $1 ---"
}

print_check() {
  echo "  ℹ️  INFO: Checking $1..."
}

print_success() {
  echo "  ✅ SUCCESS: $1"
}

print_warning() {
  echo "  ⚠️  WARNING: $1"
}

print_error() {
  echo "  ❌ FAIL: $1"
}

print_info() {
  echo "  ℹ️  INFO: $1"
}

print_skipping() {
  echo "  ⚠️  SKIP: $1"
}

# Mask sensitive values in output (e.g. API keys, passwords)
mask_value() {
  echo "**REDACTED**"
}

# ---------------------------
# Temporary file cleanup
# ---------------------------

TEMP_DIR=""
cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}
trap cleanup EXIT

TEMP_DIR=$(mktemp -d)
RESPONSE_FILE="${TEMP_DIR}/response.txt"
ERROR_FILE="${TEMP_DIR}/error.txt"

# ---------------------------
# Counters for summary
# ---------------------------

CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0
CHECKS_WARNED=0
PROXY_CONFIGURED=false

# ---------------------------
# Version comparison
# ---------------------------

# Compare two semver versions: returns 0 if $1 >= $2
version_at_least() {
  local version="$1"
  local minimum="$2"

  local v_major v_minor v_patch
  local m_major m_minor m_patch

  IFS='.' read -r v_major v_minor v_patch <<< "$version"
  IFS='.' read -r m_major m_minor m_patch <<< "$minimum"

  # Default patch to 0 if missing
  v_patch="${v_patch:-0}"
  m_patch="${m_patch:-0}"

  if (( v_major > m_major )); then return 0; fi
  if (( v_major < m_major )); then return 1; fi
  if (( v_minor > m_minor )); then return 0; fi
  if (( v_minor < m_minor )); then return 1; fi
  if (( v_patch >= m_patch )); then return 0; fi
  return 1
}

# ---------------------------
# Curl error code interpretation
# ---------------------------

interpret_curl_error() {
  local exit_code="$1"
  local error_output="$2"

  case "$exit_code" in
    5)  echo "Could not resolve proxy host" ;;
    6)  echo "DNS resolution failed" ;;
    7)  echo "Connection refused" ;;
    28) echo "Connection timeout" ;;
    35) echo "SSL handshake failed" ;;
    51) echo "SSL certificate verification failed (peer certificate)" ;;
    60) echo "SSL certificate verification failed (CA certificate)" ;;
    97) echo "HTTPS proxy handshake failed" ;;
    *)
      if [[ -n "$error_output" ]]; then
        echo "Connection failed: $error_output"
      else
        echo "Connection failed (curl exit code: $exit_code)"
      fi
      ;;
  esac
}

# ---------------------------
# Version comparison
# ---------------------------

# Compare two semver versions: returns 0 if $1 >= $2
version_at_least() {
  local version="$1"
  local minimum="$2"

  local v_major v_minor v_patch
  local m_major m_minor m_patch

  IFS='.' read -r v_major v_minor v_patch <<< "$version"
  IFS='.' read -r m_major m_minor m_patch <<< "$minimum"

  v_patch="${v_patch:-0}"
  m_patch="${m_patch:-0}"

  if (( v_major > m_major )); then return 0; fi
  if (( v_major < m_major )); then return 1; fi
  if (( v_minor > m_minor )); then return 0; fi
  if (( v_minor < m_minor )); then return 1; fi
  if (( v_patch >= m_patch )); then return 0; fi
  return 1
}

# ---------------------------
# Check 1: Proxy Configuration
# ---------------------------

check_proxy() {
  print_section "Proxy Configuration"

  local proxy_found=0
  local proxy_vars=("HTTP_PROXY" "http_proxy" "HTTPS_PROXY" "https_proxy"
                    "NO_PROXY" "no_proxy" "ALL_PROXY" "all_proxy")

  for var in "${proxy_vars[@]}"; do
    local value="${!var:-}"
    if [[ -n "$value" ]]; then
      proxy_found=1
      print_info "$var=$value"
    fi
  done

  if [[ $proxy_found -eq 0 ]]; then
    print_info "No proxy detected; using direct connection."
  else
    PROXY_CONFIGURED=true

    # Warn if HTTP proxy is set but HTTPS proxy is missing
    if [[ -n "${HTTP_PROXY:-}${http_proxy:-}" && -z "${HTTPS_PROXY:-}" && -z "${https_proxy:-}" ]]; then
      print_warning "Proxy found, but HTTPS_PROXY is missing."
    fi
  fi
}

# ---------------------------
# Check 2a: Cloud API Connectivity
# ---------------------------

check_cloud_api() {
  print_section "Elastic Cloud Connected Mode API"

  local base_url="${ELASTIC_CLOUD_CONNECTED_MODE_API_URL:-}"
  local using_default=""
  if [[ -z "$base_url" ]]; then
    base_url="https://api.elastic-cloud.com"
    using_default=" (default)"
  fi
  local check_url="${base_url}/api/v1/cloud-connected/clusters"

  print_info "URL: ${base_url}${using_default}"
  print_check "connectivity to ${check_url}"

  local http_code
  local curl_exit

  http_code=$(curl -sS -X POST \
    -H "Content-Length: 0" \
    -w "%{http_code}" \
    -o /dev/null \
    --connect-timeout 10 \
    --max-time 30 \
    "${check_url}" 2>"${ERROR_FILE}") || curl_exit=$?

  curl_exit=${curl_exit:-0}

  if [[ $curl_exit -ne 0 ]]; then
    local error_msg
    error_msg=$(interpret_curl_error "$curl_exit" "$(cat "${ERROR_FILE}" 2>/dev/null)")
    print_error "$error_msg"
    if [[ "$PROXY_CONFIGURED" == "true" && "$curl_exit" != "5" && "$curl_exit" != "97" ]]; then
      print_warning "A proxy is configured — this may be causing the connection failure"
    fi
    ((CHECKS_FAILED++))
    return 1
  fi

  # Any HTTP response means connectivity works (even 4xx/5xx)
  if [[ "$DEBUG" == "true" ]]; then
    print_success "Reachable. Can register to Elastic Cloud. (HTTP $http_code)"
  else
    print_success "Reachable. Can register to Elastic Cloud."
  fi
  ((CHECKS_PASSED++))
  return 0
}

# ---------------------------
# Check 2b: OTel Endpoint
# ---------------------------

check_otel() {
  print_section "OTel Endpoint"

  local otel_url="${AUTOOPS_OTEL_URL:-}"
  local using_default=""
  if [[ -z "$otel_url" ]]; then
    otel_url="https://otel-auto-ops.ap-northeast-1.aws.svc.elastic.cloud"
    using_default=" (default)"
  fi
  local check_url="${otel_url}/v1/logs"

  print_info "URL: ${otel_url}${using_default}"
  print_check "connectivity to ${check_url}"

  local http_code
  local curl_exit

  http_code=$(curl -sS -X POST \
    -H "Content-Length: 0" \
    -w "%{http_code}" \
    -o /dev/null \
    --connect-timeout 10 \
    --max-time 30 \
    "${check_url}" 2>"${ERROR_FILE}") || curl_exit=$?

  curl_exit=${curl_exit:-0}

  if [[ $curl_exit -ne 0 ]]; then
    local error_msg
    error_msg=$(interpret_curl_error "$curl_exit" "$(cat "${ERROR_FILE}" 2>/dev/null)")
    print_error "$error_msg"
    if [[ "$PROXY_CONFIGURED" == "true" && "$curl_exit" != "5" && "$curl_exit" != "97" ]]; then
      print_warning "A proxy is configured — this may be causing the connection failure"
    fi
    ((CHECKS_FAILED++))
    return 1
  fi

  if [[ "$DEBUG" == "true" ]]; then
    print_success "Reachable. Can ship metrics to Elastic Cloud. (HTTP $http_code)"
  else
    print_success "Reachable. Can ship metrics to Elastic Cloud."
  fi
  ((CHECKS_PASSED++))
  return 0
}

# ---------------------------
# Check 3: Elasticsearch
# ---------------------------

check_elasticsearch() {
  print_section "Elasticsearch"

  if [[ -z "${AUTOOPS_ES_URL:-}" ]]; then
    print_skipping "Elasticsearch check skipped (AUTOOPS_ES_URL not set). Set AUTOOPS_ES_URL to enable connectivity testing"
    ((CHECKS_SKIPPED++))
    return 0
  fi

  # Normalize URL (remove trailing slash, then add it)
  local es_url="${AUTOOPS_ES_URL%/}/"

  print_info "URL: ${AUTOOPS_ES_URL}"

  # Build auth options
  local auth_opts=()
  local auth_type="none"

  if [[ -n "${AUTOOPS_ES_API_KEY:-}" ]]; then
    auth_opts=(-H "Authorization: ApiKey ${AUTOOPS_ES_API_KEY}")
    auth_type="ApiKey"
    print_info "Auth: ApiKey $(mask_value "${AUTOOPS_ES_API_KEY}")"
  elif [[ -n "${AUTOOPS_ES_USERNAME:-}" && -n "${AUTOOPS_ES_PASSWORD:-}" ]]; then
    auth_opts=(-u "${AUTOOPS_ES_USERNAME}:${AUTOOPS_ES_PASSWORD}")
    auth_type="Basic"
    print_info "Auth: Basic ${AUTOOPS_ES_USERNAME}:$(mask_value "${AUTOOPS_ES_PASSWORD}")"
  else
    print_info "Auth: none"
  fi

  # CA certificate handling
  local ca_opts=()
  local ca_warning=""

  if [[ -n "${AUTOOPS_ES_CA:-}" ]]; then
    print_info "CA: ${AUTOOPS_ES_CA}"

    if [[ ! -f "${AUTOOPS_ES_CA}" ]]; then
      print_error "CA certificate file not found: ${AUTOOPS_ES_CA}."
      ((CHECKS_FAILED++))
      return 1
    fi

    # First, try WITHOUT the CA to see if it's necessary
    print_check "if CA certificate is required"

    local test_http_code
    local test_curl_exit

    test_http_code=$(curl -sS \
      "${auth_opts[@]}" \
      -w "%{http_code}" \
      -o /dev/null \
      --connect-timeout 10 \
      --max-time 30 \
      "${es_url}" 2>"${ERROR_FILE}") || test_curl_exit=$?

    test_curl_exit=${test_curl_exit:-0}

    # If connection succeeded without CA, warn the user
    if [[ $test_curl_exit -eq 0 ]]; then
      ca_warning="Connection secure without provided CA file."
    fi

    ca_opts=(--cacert "${AUTOOPS_ES_CA}")
  fi

  print_check "connectivity to ${es_url}"

  local http_code
  local curl_exit

  http_code=$(curl -sS \
    "${ca_opts[@]}" \
    "${auth_opts[@]}" \
    -w "%{http_code}" \
    -o "${RESPONSE_FILE}" \
    --connect-timeout 10 \
    --max-time 30 \
    "${es_url}" 2>"${ERROR_FILE}") || curl_exit=$?

  curl_exit=${curl_exit:-0}

  # Handle curl errors
  if [[ $curl_exit -ne 0 ]]; then
    local error_msg
    error_msg=$(interpret_curl_error "$curl_exit" "$(cat "${ERROR_FILE}" 2>/dev/null)")
    print_error "$error_msg"
    if [[ "$PROXY_CONFIGURED" == "true" && "$curl_exit" != "5" && "$curl_exit" != "97" ]]; then
      print_warning "A proxy is configured — this may be causing the connection failure"
    fi
    ((CHECKS_FAILED++))
    return 1
  fi

  # Handle HTTP errors
  case "$http_code" in
    200)
      print_success "Connected successfully (HTTP 200)"

      # Try to extract cluster info from response
      if [[ -f "${RESPONSE_FILE}" ]]; then
        local cluster_name
        local version
        cluster_name=$(grep -o '"cluster_name"[[:space:]]*:[[:space:]]*"[^"]*"' "${RESPONSE_FILE}" 2>/dev/null | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/')
        version=$(grep -o '"number"[[:space:]]*:[[:space:]]*"[^"]*"' "${RESPONSE_FILE}" 2>/dev/null | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/')

        if [[ -n "$cluster_name" ]]; then
          print_info "Cluster: $cluster_name"
        fi
        if [[ -n "$version" ]]; then
          print_info "Version: $version"
          if ! version_at_least "$version" "7.17.0"; then
            print_error "Elasticsearch version $version is below the minimum required version 7.17.0"
            ((CHECKS_FAILED++))
            return 1
          fi
        fi

        # Check license status
        local license_url="${AUTOOPS_ES_URL%/}/_license"
        print_check "license status at ${license_url}"

        local license_http_code
        local license_curl_exit

        license_http_code=$(curl -sS \
          "${ca_opts[@]}" \
          "${auth_opts[@]}" \
          -w "%{http_code}" \
          -o "${RESPONSE_FILE}" \
          --connect-timeout 10 \
          --max-time 30 \
          "${license_url}" 2>"${ERROR_FILE}") || license_curl_exit=$?

        license_curl_exit=${license_curl_exit:-0}

        if [[ $license_curl_exit -ne 0 ]]; then
          local error_msg
          error_msg=$(interpret_curl_error "$license_curl_exit" "$(cat "${ERROR_FILE}" 2>/dev/null)")
          print_error "License check failed: $error_msg"
          if [[ "$PROXY_CONFIGURED" == "true" && "$license_curl_exit" != "5" && "$license_curl_exit" != "97" ]]; then
            print_warning "A proxy is configured — this may be causing the connection failure"
          fi
          ((CHECKS_FAILED++))
          return 1
        fi

        if [[ "$license_http_code" != "200" ]]; then
          print_error "License check failed (HTTP $license_http_code)"
          ((CHECKS_FAILED++))
          return 1
        fi

        # Extract license status, type, and uid from response
        local license_status
        local license_type
        local license_uid
        license_status=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "${RESPONSE_FILE}" 2>/dev/null | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/')
        license_type=$(grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' "${RESPONSE_FILE}" 2>/dev/null | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/')
        license_uid=$(grep -o '"uid"[[:space:]]*:[[:space:]]*"[^"]*"' "${RESPONSE_FILE}" 2>/dev/null | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/')

        if [[ "$license_status" == "active" ]]; then
          local license_detail=""
          if [[ -n "$license_type" && -n "$license_uid" ]]; then
            license_detail=" ($license_type: $license_uid)"
          elif [[ -n "$license_type" ]]; then
            license_detail=" ($license_type)"
          fi
          print_success "License: active${license_detail}"
        elif [[ -n "$license_status" ]]; then
          print_error "License status is \"$license_status\" (expected \"active\")"
          ((CHECKS_FAILED++))
          return 1
        else
          print_warning "Could not determine license status from response"
          ((CHECKS_WARNED++))
        fi
      fi

      if [[ -n "$ca_warning" ]]; then
        print_warning "$ca_warning"
        ((CHECKS_WARNED++))
      fi

      ((CHECKS_PASSED++))
      return 0
      ;;
    401)
      print_error "Authentication failed (HTTP 401 Unauthorized). Check for typos."
      ((CHECKS_FAILED++))
      return 1
      ;;
    403)
      print_error "Authorization denied (HTTP 403 Forbidden)."
      ((CHECKS_FAILED++))
      return 1
      ;;
    *)
      print_warning "Received HTTP $http_code (connectivity OK, but unexpected response)"
      if [[ -n "$ca_warning" ]]; then
        print_warning "$ca_warning"
        ((CHECKS_WARNED++))
      fi
      ((CHECKS_PASSED++))
      return 0
      ;;
  esac
}

# ---------------------------
# Summary
# ---------------------------

print_summary() {
  print_section "Summary"

  local total=$((CHECKS_PASSED + CHECKS_FAILED + CHECKS_SKIPPED))

  echo ""
  echo "  Passed:  $CHECKS_PASSED"
  echo "  Failed:  $CHECKS_FAILED"
  echo "  Skipped: $CHECKS_SKIPPED"
  if [[ $CHECKS_WARNED -gt 0 ]]; then
    echo "  Warnings: $CHECKS_WARNED"
  fi
  echo ""

  if [[ $CHECKS_FAILED -gt 0 ]]; then
    print_error "Connectivity issues detected. AutoOps Agent will not function. Review troubleshooting guide and address issues before running the agent."
    return 1
  else
    print_success "All checks passed. The environment is ready to use AutoOps."
    return 0
  fi
}

# ---------------------------
# Main
# ---------------------------

main() {
  print_header

  check_proxy
  check_cloud_api
  check_otel
  check_elasticsearch

  print_summary
  exit $?
}

main
