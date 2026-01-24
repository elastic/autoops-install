#!/bin/bash
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License
# 2.0; you may not use this file except in compliance with the Elastic License
# 2.0.
#

# Test script for check_connectivity.sh
# Runs various test scenarios using a Python mock HTTP server

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="${SCRIPT_DIR}/check_connectivity.sh"

# ---------------------------
# Test framework
# ---------------------------

TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

# Colors for output (disabled if not a terminal)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  NC='\033[0m' # No Color
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

log_test() {
  CURRENT_TEST="$1"
  echo ""
  echo -e "${YELLOW}TEST: $1${NC}"
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
  local expected="$1"
  local actual="$2"
  if [[ "$actual" -eq "$expected" ]]; then
    log_pass "Exit code is $expected"
  else
    log_fail "Expected exit code $expected, got $actual"
  fi
}

assert_output_contains() {
  local pattern="$1"
  local output="$2"
  if echo "$output" | grep -q "$pattern"; then
    log_pass "Output contains '$pattern'"
  else
    log_fail "Output should contain '$pattern'"
  fi
}

assert_output_not_contains() {
  local pattern="$1"
  local output="$2"
  if echo "$output" | grep -q "$pattern"; then
    log_fail "Output should NOT contain '$pattern'"
  else
    log_pass "Output does not contain '$pattern'"
  fi
}

# ---------------------------
# Mock HTTP server (Python)
# ---------------------------

MOCK_SERVER_PID=""
MOCK_SERVER_PORT=""
MOCK_SERVER_DIR=""

start_mock_server() {
  local response_code="$1"
  local response_body="${2:-}"

  MOCK_SERVER_DIR=$(mktemp -d)
  MOCK_SERVER_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')

  # Create Python mock server script
  cat > "${MOCK_SERVER_DIR}/server.py" << EOF
import http.server
import sys

class MockHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress logging

    def do_GET(self):
        self.send_response(${response_code})
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'${response_body}')

    def do_POST(self):
        self.do_GET()

if __name__ == '__main__':
    server = http.server.HTTPServer(('127.0.0.1', ${MOCK_SERVER_PORT}), MockHandler)
    server.handle_request()  # Handle one request then exit
EOF

  # Start server in background
  python3 "${MOCK_SERVER_DIR}/server.py" &
  MOCK_SERVER_PID=$!

  # Brief pause to let server start
  sleep 0.2

  export MOCK_SERVER_URL="http://127.0.0.1:${MOCK_SERVER_PORT}"
}

stop_mock_server() {
  if [[ -n "${MOCK_SERVER_PID:-}" ]]; then
    kill "${MOCK_SERVER_PID}" 2>/dev/null || true
    wait "${MOCK_SERVER_PID}" 2>/dev/null || true
    MOCK_SERVER_PID=""
  fi
  if [[ -n "${MOCK_SERVER_DIR:-}" && -d "${MOCK_SERVER_DIR}" ]]; then
    rm -rf "${MOCK_SERVER_DIR}"
    MOCK_SERVER_DIR=""
  fi
}

# Multi-request server for tests that need multiple requests
start_multi_mock_server() {
  local response_code="$1"
  local response_body="${2:-}"
  local num_requests="${3:-5}"

  MOCK_SERVER_DIR=$(mktemp -d)
  MOCK_SERVER_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')

  cat > "${MOCK_SERVER_DIR}/server.py" << EOF
import http.server

class MockHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        self.send_response(${response_code})
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'${response_body}')

    def do_POST(self):
        self.do_GET()

if __name__ == '__main__':
    server = http.server.HTTPServer(('127.0.0.1', ${MOCK_SERVER_PORT}), MockHandler)
    for _ in range(${num_requests}):
        server.handle_request()
EOF

  python3 "${MOCK_SERVER_DIR}/server.py" &
  MOCK_SERVER_PID=$!
  sleep 0.3

  export MOCK_SERVER_URL="http://127.0.0.1:${MOCK_SERVER_PORT}"
}

# Cleanup on exit
cleanup() {
  stop_mock_server
}
trap cleanup EXIT

# ---------------------------
# Test Cases
# ---------------------------

test_proxy_detection() {
  log_test "Proxy detection - no proxy configured"

  local output
  local exit_code=0

  output=$(
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy ALL_PROXY all_proxy
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  assert_output_contains "No proxy environment variables configured" "$output"
}

test_proxy_detection_with_proxy() {
  log_test "Proxy detection - proxy configured"

  local output
  local exit_code=0

  output=$(
    unset http_proxy https_proxy no_proxy all_proxy
    HTTP_PROXY="http://myproxy.example.com:8080" \
    HTTPS_PROXY="http://secureproxy.example.com:8443" \
    NO_PROXY="localhost,127.0.0.1" \
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  assert_output_contains "HTTP_PROXY=" "$output"
  assert_output_contains "HTTPS_PROXY=" "$output"
  assert_output_contains "NO_PROXY=" "$output"
  # Check that values are masked (contains ...)
  assert_output_contains "\.\.\." "$output"
}

test_cloud_api_success() {
  log_test "Cloud API - successful connection"

  start_mock_server "200" '{"status": "ok"}'

  local output
  local exit_code=0

  output=$(
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="${MOCK_SERVER_URL}" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  stop_mock_server

  assert_output_contains "Connected (HTTP 200)" "$output"
}

test_cloud_api_connection_refused() {
  log_test "Cloud API - connection refused"

  local output
  local exit_code=0

  output=$(
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  assert_exit_code 1 "$exit_code"
  assert_output_contains "Connection failed" "$output"
}

test_otel_success() {
  log_test "OTel endpoint - successful connection"

  start_mock_server "200" '{"status": "ok"}'

  local output
  local exit_code=0

  output=$(
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="${MOCK_SERVER_URL}" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  stop_mock_server

  assert_output_contains "OTel Endpoint" "$output"
  assert_output_contains "Connected (HTTP 200)" "$output"
}

test_otel_default_url() {
  log_test "OTel endpoint - uses default URL when not set"

  local output
  local exit_code=0

  output=$(
    unset AUTOOPS_OTEL_URL
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  assert_output_contains "otel-auto-ops.ap-northeast-1.aws.svc.elastic.cloud" "$output"
}

test_elasticsearch_skipped() {
  log_test "Elasticsearch - skipped when URL not set"

  local output
  local exit_code=0

  output=$(
    unset AUTOOPS_ES_URL
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  assert_output_contains "AUTOOPS_ES_URL not set - skipping" "$output"
  assert_output_contains "Skipped: 1" "$output"
}

test_elasticsearch_success() {
  log_test "Elasticsearch - successful connection"

  start_mock_server "200" '{"cluster_name": "test-cluster", "version": {"number": "8.12.0"}}'

  local output
  local exit_code=0

  output=$(
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    AUTOOPS_ES_URL="${MOCK_SERVER_URL}" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  stop_mock_server

  assert_output_contains "Connected successfully (HTTP 200)" "$output"
  assert_output_contains "Cluster: test-cluster" "$output"
  assert_output_contains "Version: 8.12.0" "$output"
}

test_elasticsearch_with_api_key() {
  log_test "Elasticsearch - API key authentication display"

  start_mock_server "200" '{"cluster_name": "test-cluster"}'

  local output
  local exit_code=0

  output=$(
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    AUTOOPS_ES_URL="${MOCK_SERVER_URL}" \
    AUTOOPS_ES_API_KEY="abcdefghijklmnop" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  stop_mock_server

  assert_output_contains "Auth: ApiKey abcd...mnop" "$output"
}

test_elasticsearch_with_basic_auth() {
  log_test "Elasticsearch - Basic authentication display"

  start_mock_server "200" '{"cluster_name": "test-cluster"}'

  local output
  local exit_code=0

  output=$(
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    AUTOOPS_ES_URL="${MOCK_SERVER_URL}" \
    AUTOOPS_ES_USERNAME="elastic" \
    AUTOOPS_ES_PASSWORD="supersecretpassword" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  stop_mock_server

  assert_output_contains "Auth: Basic elastic:" "$output"
  # Password should be masked
  assert_output_contains "supe...word" "$output"
}

test_elasticsearch_auth_failure_401() {
  log_test "Elasticsearch - authentication failure (401)"

  start_mock_server "401" '{"error": "Unauthorized"}'

  local output
  local exit_code=0

  output=$(
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    AUTOOPS_ES_URL="${MOCK_SERVER_URL}" \
    AUTOOPS_ES_API_KEY="invalid-key" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  stop_mock_server

  assert_exit_code 1 "$exit_code"
  assert_output_contains "Authentication failed (HTTP 401 Unauthorized)" "$output"
}

test_elasticsearch_auth_failure_403() {
  log_test "Elasticsearch - authorization failure (403)"

  start_mock_server "403" '{"error": "Forbidden"}'

  local output
  local exit_code=0

  output=$(
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    AUTOOPS_ES_URL="${MOCK_SERVER_URL}" \
    AUTOOPS_ES_API_KEY="limited-key" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  stop_mock_server

  assert_exit_code 1 "$exit_code"
  assert_output_contains "Authorization denied (HTTP 403 Forbidden)" "$output"
}

test_elasticsearch_ca_not_found() {
  log_test "Elasticsearch - CA certificate file not found"

  local output
  local exit_code=0

  output=$(
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    AUTOOPS_ES_URL="http://127.0.0.1:1" \
    AUTOOPS_ES_CA="/nonexistent/path/to/ca.crt" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  assert_exit_code 1 "$exit_code"
  assert_output_contains "CA certificate file not found" "$output"
}

test_value_masking_short() {
  log_test "Value masking - short values fully masked"

  start_mock_server "200" '{}'

  local output
  local exit_code=0

  output=$(
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    AUTOOPS_ES_URL="${MOCK_SERVER_URL}" \
    AUTOOPS_ES_API_KEY="short" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  stop_mock_server

  # Short values (8 chars or less) should show ****
  assert_output_contains 'Auth: ApiKey \*\*\*\*' "$output"
}

test_summary_all_pass() {
  log_test "Summary - all checks pass"

  start_multi_mock_server "200" '{"cluster_name": "test"}' 5

  local output
  local exit_code=0

  output=$(
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="${MOCK_SERVER_URL}" \
    AUTOOPS_OTEL_URL="${MOCK_SERVER_URL}" \
    AUTOOPS_ES_URL="${MOCK_SERVER_URL}" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  stop_mock_server

  assert_exit_code 0 "$exit_code"
  assert_output_contains "Result: All checks passed" "$output"
}

test_summary_some_fail() {
  log_test "Summary - some checks fail"

  local output
  local exit_code=0

  output=$(
    ELASTIC_CLOUD_CONNECTED_MODE_API_URL="http://127.0.0.1:1" \
    AUTOOPS_OTEL_URL="http://127.0.0.1:1" \
    bash "$CHECK_SCRIPT" 2>&1
  ) || exit_code=$?

  assert_exit_code 1 "$exit_code"
  assert_output_contains "Result: Some checks failed" "$output"
}

# ---------------------------
# Run all tests
# ---------------------------

run_all_tests() {
  echo "========================================"
  echo "  check_connectivity.sh Test Suite"
  echo "========================================"

  # Check dependencies
  if ! command -v python3 &> /dev/null; then
    echo ""
    echo -e "${RED}ERROR: 'python3' is required but not installed${NC}"
    exit 1
  fi

  if ! command -v curl &> /dev/null; then
    echo ""
    echo -e "${RED}ERROR: 'curl' is required but not installed${NC}"
    exit 1
  fi

  # Verify script exists
  if [[ ! -f "$CHECK_SCRIPT" ]]; then
    echo ""
    echo -e "${RED}ERROR: check_connectivity.sh not found at $CHECK_SCRIPT${NC}"
    exit 1
  fi

  # Run tests
  test_proxy_detection
  test_proxy_detection_with_proxy
  test_cloud_api_success
  test_cloud_api_connection_refused
  test_otel_success
  test_otel_default_url
  test_elasticsearch_skipped
  test_elasticsearch_success
  test_elasticsearch_with_api_key
  test_elasticsearch_with_basic_auth
  test_elasticsearch_auth_failure_401
  test_elasticsearch_auth_failure_403
  test_elasticsearch_ca_not_found
  test_value_masking_short
  test_summary_all_pass
  test_summary_some_fail

  # Print summary
  echo ""
  echo "========================================"
  echo "  Test Results"
  echo "========================================"
  echo ""
  echo -e "  ${GREEN}Passed${NC}: $TESTS_PASSED"
  echo -e "  ${RED}Failed${NC}: $TESTS_FAILED"
  echo ""

  if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "  ${RED}SOME TESTS FAILED${NC}"
    exit 1
  else
    echo -e "  ${GREEN}ALL TESTS PASSED${NC}"
    exit 0
  fi
}

run_all_tests
