#!/bin/bash
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License
# 2.0; you may not use this file except in compliance with the Elastic License
# 2.0.
#

# Usage example:
# ./check_connectivity.sh
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
  echo "  Checking $1..."
}

print_success() {
  echo "  $1"
}

print_warning() {
  echo "  $1"
}

print_error() {
  echo "  $1"
}

print_info() {
  echo "  $1"
}

# Mask sensitive values: show first 4 and last 4 characters
mask_value() {
  local value="$1"
  local len=${#value}
  if [[ $len -le 8 ]]; then
    echo "****"
  else
    echo "${value:0:4}...${value: -4}"
  fi
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

# ---------------------------
# Curl error code interpretation
# ---------------------------

interpret_curl_error() {
  local exit_code="$1"
  local error_output="$2"

  case "$exit_code" in
    6)  echo "DNS resolution failed" ;;
    7)  echo "Connection refused" ;;
    28) echo "Connection timeout" ;;
    35) echo "SSL handshake failed" ;;
    51) echo "SSL certificate verification failed (peer certificate)" ;;
    60) echo "SSL certificate verification failed (CA certificate)" ;;
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
      print_info "$var=$(mask_value "$value")"
    fi
  done

  if [[ $proxy_found -eq 0 ]]; then
    print_info "No proxy environment variables configured"
  fi
}

# ---------------------------
# Check 2a: Cloud API Connectivity
# ---------------------------

check_cloud_api() {
  print_section "Elastic Cloud Connected Mode API"

  local base_url="${ELASTIC_CLOUD_CONNECTED_MODE_API_URL:-https://api.elastic-cloud.com}"
  local check_url="${base_url}/api/v1/cloud-connected/clusters"

  print_info "URL: $base_url"
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
    print_error "Connection failed: $error_msg"
    ((CHECKS_FAILED++))
    return 1
  fi

  # Any HTTP response means connectivity works (even 4xx/5xx)
  print_success "Connected (HTTP $http_code)"
  ((CHECKS_PASSED++))
  return 0
}

# ---------------------------
# Check 2b: OTel Endpoint
# ---------------------------

check_otel() {
  print_section "OTel Endpoint"

  local otel_url="${AUTOOPS_OTEL_URL:-https://otel-auto-ops.ap-northeast-1.aws.svc.elastic.cloud}"
  local check_url="${otel_url}/v1/logs"

  print_info "URL: ${otel_url}"
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
    print_error "Connection failed: $error_msg"
    ((CHECKS_FAILED++))
    return 1
  fi

  print_success "Connected (HTTP $http_code)"
  ((CHECKS_PASSED++))
  return 0
}

# ---------------------------
# Check 3: Elasticsearch
# ---------------------------

check_elasticsearch() {
  print_section "Elasticsearch"

  if [[ -z "${AUTOOPS_ES_URL:-}" ]]; then
    print_info "AUTOOPS_ES_URL not set - skipping"
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
      print_error "CA certificate file not found: ${AUTOOPS_ES_CA}"
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
      ca_warning="CA certificate may not be required (connection succeeded without it)"
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
    print_error "Connection failed: $error_msg"
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
      print_error "Authentication failed (HTTP 401 Unauthorized)"
      ((CHECKS_FAILED++))
      return 1
      ;;
    403)
      print_error "Authorization denied (HTTP 403 Forbidden)"
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
    echo "  Result: Some checks failed"
    return 1
  else
    echo "  Result: All checks passed"
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
