#!/bin/bash

# Usage example:
# ./install_autoops.sh \
#   --version 9.1.2 \
#   --token abc123 \
#   --ccm-api-key xyz789 \
#   --otel-endpoint https://otel-url.co:4318 \
#   --es-endpoint https://es-url.co:9200 \
#   --es-username myuser \
#   --es-password mypass \
#   --temp-resource-id my-es-cluster

# ---------------------------
# Configurable defaults
# ---------------------------
DOWNLOAD_URL="https://artifacts.elastic.co/downloads/beats/elastic-agent"
VERSION="9.1.0"
DO_NOT_DELETE=false
CACHE_DIR="${AUTOOPS_CACHE_DIR:-$HOME/.cache/elastic-agent-installer}"
ELASTIC_CLOUD_CONNECTED_MODE_API_URL=""

# Required (populated by flags)
AUTOOPS_ES_URL=""
AUTOOPS_OTEL_URL=""
AUTOOPS_TEMP_RESOURCE_ID=""
AUTOOPS_TOKEN=""
ELASTIC_CLOUD_CONNECTED_MODE_API_KEY=""

# Optional creds (user/pass OR api key)
ELASTICSEARCH_READ_USERNAME=""
ELASTICSEARCH_READ_PASSWORD=""
ELASTICSEARCH_READ_API_KEY=""

# ---------------------------
# Parse args
# ---------------------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --es-endpoint) AUTOOPS_ES_URL="$2"; shift 2;;
    --otel-endpoint) AUTOOPS_OTEL_URL="$2"; shift 2;;
    --token) AUTOOPS_TOKEN="$2"; shift 2;;
    --ccm-api-key) ELASTIC_CLOUD_CONNECTED_MODE_API_KEY="$2"; shift 2;;
    --ccm-api-url) ELASTIC_CLOUD_CONNECTED_MODE_API_URL="$2"; shift 2;;
    --temp-resource-id) AUTOOPS_TEMP_RESOURCE_ID="$2"; shift 2;;
    --es-username) ELASTICSEARCH_READ_USERNAME="$2"; shift 2;;
    --es-password) ELASTICSEARCH_READ_PASSWORD="$2"; shift 2;;
    --es-api-key) ELASTICSEARCH_READ_API_KEY="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --download-url) DOWNLOAD_URL="$2"; shift 2;;
    --cache-dir) CACHE_DIR="$2"; shift 2;;
    --do-not-delete) DO_NOT_DELETE=true; shift;;
    *) echo "Unknown parameter: $1"; exit 1;;
  esac
done

# ---------------------------
# Validate inputs
# ---------------------------
if [[ -z "$VERSION" ]]; then
  echo "Error: --version required"; exit 1
elif [[ -z "$AUTOOPS_TEMP_RESOURCE_ID" ]]; then
  echo "Error: --temp-resource-id required"; exit 1
elif [[ -z "$AUTOOPS_TOKEN" ]]; then
  echo "Error: --token required"; exit 1
elif [[ -z "$AUTOOPS_ES_URL" ]]; then
  echo "Error: --es-endpoint required"; exit 1
elif [[ -z "$AUTOOPS_OTEL_URL" ]]; then
  echo "Error: --otel-endpoint required"; exit 1
elif [[ -z "$ELASTIC_CLOUD_CONNECTED_MODE_API_KEY" ]]; then
  echo "Error: --ccm-api-key required"; exit 1
elif [[ -n "$ELASTICSEARCH_READ_API_KEY" && ( -n "$ELASTICSEARCH_READ_USERNAME" || -n "$ELASTICSEARCH_READ_PASSWORD" ) ]]; then
  echo "Error: --es-api-key cannot be combined with --es-username/--es-password"; exit 1
elif [[ ( -n "$ELASTICSEARCH_READ_USERNAME" && -z "$ELASTICSEARCH_READ_PASSWORD" ) || ( -z "$ELASTICSEARCH_READ_USERNAME" && -n "$ELASTICSEARCH_READ_PASSWORD" ) ]]; then
  echo "Error: --es-username and --es-password must be provided together"; exit 1
fi

# ---------------------------
# Arch mapping to Elastic filenames
# ---------------------------
UNAME_ARCH="$(uname -m)"
case "$UNAME_ARCH" in
  x86_64|amd64) AGENT_ARCH="x86_64" ;;
  aarch64|arm64) AGENT_ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: $UNAME_ARCH"
    echo "Supported: x86_64, arm64"
    exit 1
    ;;
esac

TAR_FILE="elastic-agent-${VERSION}-linux-${AGENT_ARCH}.tar.gz"
CACHE_PATH="${CACHE_DIR}/${TAR_FILE}"

# ---------------------------
# Temp dir & cleanup
# ---------------------------
TEMP_DIR="$(mktemp -d)"
echo "Temporary directory: ${TEMP_DIR}"

if [ "$DO_NOT_DELETE" = false ]; then
  trap 'echo "Cleaning up ${TEMP_DIR}"; rm -rf "${TEMP_DIR}"' EXIT
fi

mkdir -p "${CACHE_DIR}"

# ---------------------------
# Download (with cache)
# ---------------------------
download_with_cache() {
  echo "Looking for cached package: ${CACHE_PATH}"
  if [[ -s "${CACHE_PATH}" ]]; then
    # Validate cached tarball
    if tar -tzf "${CACHE_PATH}" >/dev/null 2>&1; then
      echo "✅ Using cached ${TAR_FILE}"
      return 0
    else
      echo "⚠️  Cached file seems corrupted; re-downloading…"
      rm -f "${CACHE_PATH}"
    fi
  fi

  echo "Downloading Elastic Agent: ${TAR_FILE}"
  curl -fL --retry 3 --retry-delay 2 -o "${CACHE_PATH}" "${DOWNLOAD_URL}/${TAR_FILE}" || {
    echo "Error: download failed: ${DOWNLOAD_URL}/${TAR_FILE}"
    rm -f "${CACHE_PATH}"
    exit 1
  }

  # Validate fresh download
  if ! tar -tzf "${CACHE_PATH}" >/dev/null 2>&1; then
    echo "Error: downloaded tarball is invalid (${CACHE_PATH})"
    rm -f "${CACHE_PATH}"
    exit 1
  fi
}

download_with_cache

# Work from temp dir, copy cached tar there
cd "${TEMP_DIR}"
cp "${CACHE_PATH}" "./${TAR_FILE}"

echo "Extracting ${TAR_FILE}…"
tar xzvf "${TAR_FILE}" >/dev/null

AGENT_DIR="elastic-agent-${VERSION}-linux-${AGENT_ARCH}"
if [[ ! -d "${AGENT_DIR}" ]]; then
  echo "Error: expected directory ${AGENT_DIR} after extraction"
  exit 1
fi
cd "${AGENT_DIR}"

# ---------------------------
# Prepare config
# ---------------------------
if [[ ! -s "./otel_samples/autoops_es.yml" ]]; then
  echo "Error: Missing otel_samples/autoops_es.yml for version [${VERSION}]"
  exit 1
fi

cp ./otel_samples/autoops_es.yml elastic-agent.yml

# ---------------------------
# Install agent
# ---------------------------
echo "Installing Elastic Agent…"
sudo ./elastic-agent install

# ---------------------------
# Systemd env injection
# ---------------------------
echo "Configuring systemd env vars…"
sudo mkdir -p /etc/systemd/system/elastic-agent.service.d

sudo tee /etc/systemd/system/elastic-agent.service.d/autoops-env.conf >/dev/null <<EOF
[Service]
Environment="AUTOOPS_ES_URL=${AUTOOPS_ES_URL}"
Environment="AUTOOPS_OTEL_URL=${AUTOOPS_OTEL_URL}"
Environment="AUTOOPS_TOKEN=${AUTOOPS_TOKEN}"
Environment="AUTOOPS_TEMP_RESOURCE_ID=${AUTOOPS_TEMP_RESOURCE_ID}"
Environment="ELASTIC_CLOUD_CONNECTED_MODE_API_KEY=${ELASTIC_CLOUD_CONNECTED_MODE_API_KEY}"
Environment="ELASTIC_CLOUD_CONNECTED_MODE_API_URL=${ELASTIC_CLOUD_CONNECTED_MODE_API_URL}"
Environment="ELASTICSEARCH_READ_USERNAME=${ELASTICSEARCH_READ_USERNAME}"
Environment="ELASTICSEARCH_READ_PASSWORD=${ELASTICSEARCH_READ_PASSWORD}"
Environment="ELASTICSEARCH_READ_API_KEY=${ELASTICSEARCH_READ_API_KEY}"
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl restart elastic-agent

echo "✅ Done."
echo "Status: sudo systemctl status elastic-agent"
echo "Logs:   journalctl -u elastic-agent -f"
echo "Cache:  ${CACHE_PATH} (set AUTOOPS_CACHE_DIR to change)"
