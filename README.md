# autoops-install

Install scripts to simplify the installation of AutoOps with your Self-Managed clusters.

# Kubernetes Installation

Instructions for the Kubernetes installation are provided by the AutoOps Installation Wizard. However, examples are shown below for posterity.

Use the `k8s/autoops_agent_deployment.yaml` deployment configuration to install a new agent in your Kubernetes cluster.

| Parameter | Optional | Description |
|-----------|----------|----------|
| `autoops-otel-endpoint` | No  | The URL where OTel data is delivered for AutoOps. |
| `ccm-api-key` | No  | The Elastic Cloud API Key that allows the cluster to be registered. |
| `ccm-api-url` | Yes | The Elastic Cloud endpoint that allows the cluster to be registered. |
| `temp-resource-id` | No | The ID used to allow the wizard to recognize when the resource has been added. |
| `autoops-es-url` | No | The Elasticsearch endpoint to fetch data from Elasticsearch. |
| `es-username` | Yes | The Elasticsearch username used to fetch data from Elasticsearch. Requires password. |
| `es-password` | Yes | The Elasticsearch password used to fetch data from Elasticsearch. Requires username. |
| `es-api-key` | Yes | The Elasticsearch API Key used to fetch data from Elasticsearch. Cannot be suppled with username or password. |

### Installation with Elasticsearch Basic Auth (Username / Password)

```sh
kubectl create secret generic autoops-secret \
  --from-literal=temp-resource-id="<Provided by AutoOps installation wizard>" \
  --from-literal=autoops-otel-url="<Provided by AutoOps installation wizard>" \
  --from-literal=cloud-connected-mode-api-key="<Provided by AutoOps installation wizard>" \
  --from-literal=cloud-connected-mode-api-url="<Provided by AutoOps installation wizard if needed>" \
  --from-literal=autoops-es-url="<your-es-url>" \
  --from-literal=es-username="<your-es-username>" \
  --from-literal=es-password="<your-es-password>" && \
kubectl apply -f https://raw.githubusercontent.com/elastic/autoops-install/main/k8s/autoops_agent_deployment.yaml
```

### Installation with Elasticsearch API Key

```sh
kubectl create secret generic autoops-secret \
  --from-literal=temp-resource-id="<Provided by AutoOps installation wizard>" \
  --from-literal=autoops-otel-url="<Provided by AutoOps installation wizard>" \
  --from-literal=cloud-connected-mode-api-key="<Provided by AutoOps installation wizard>" \
  --from-literal=cloud-connected-mode-api-url="<Provided by AutoOps installation wizard if needed>" \
  --from-literal=autoops-es-url="<your-es-url>" \
  --from-literal=es-api-key="<your-es-api-key>" && \
kubectl apply -f https://raw.githubusercontent.com/elastic/autoops-install/main/k8s/autoops_agent_deployment.yaml
```

# Linux Installation

Copy or otherwise use the script located in `linux/install_autoops.sh`. This script uses the Elastic Agent's installer and to install it as a service and sets the CLI parameters as configuration for it.

Use the `install_autoops.sh` script in order to install a new agent on your Linux machine.

| Parameter | Optional | Description |
|-----------|----------|----------|
| `otel-endpoint` | No  | The URL where OTel data is delivered for AutoOps. |
| `ccm-api-key` | No  | The Elastic Cloud API Key that allows the cluster to be registered. |
| `ccm-api-url` | Yes | The Elastic Cloud endpoint that allows the cluster to be registered. |
| `temp-resource-id` | No | The ID used to allow the wizard to recognize when the resource has been added. |
| `es-endpoint` | No | The Elasticsearch endpoint to fetch data from Elasticsearch. |
| `es-username` | Yes | The Elasticsearch username used to fetch data from Elasticsearch. Requires password. |
| `es-password` | Yes | The Elasticsearch password used to fetch data from Elasticsearch. Requires username. |
| `es-api-key` | Yes | The Elasticsearch API Key used to fetch data from Elasticsearch. Cannot be suppled with username or password. |
| `version` | Yes | Allows the version of the Elastic Agent to be overridden. Has to be 9.1.4 or later. **Note**: does **not** need to match the Elastic Stack version and this should not be used unless requested. |

### Installation with Elasticsearch Basic Auth (Username / Password)

```sh
./install_autoops.sh \
  --otel-endpoint "<Provided by AutoOps installation wizard>" \
  --ccm-api-key "<Provided by AutoOps installation wizard>" \
  --ccm-api-url "<Provided by AutoOps installation wizard if needed>" \
  --temp-resource-id "<Provided by AutoOps installation wizard>" \
  --es-endpoint "<your-es-url>" \
  --es-username "<your-es-user>" \
  --es-password "<your-es-pass>"
```

### Installation with Elasticsearch API Key

```sh
./install_autoops.sh \
  --otel-endpoint "<Provided by AutoOps installation wizard>" \
  --ccm-api-key "<Provided by AutoOps installation wizard>" \
  --ccm-api-url "<Provided by AutoOps installation wizard if needed>" \
  --temp-resource-id "<Provided by AutoOps installation wizard>" \
  --es-endpoint "<your-es-url>" \
  --es-api-key "<your-es-api-key>"
```

# Upgrading an installed agent

Use `upgrade/upgrade_autoops.sh` to move an installed agent to a newer version without reinstalling it. Your credentials and settings stay as they are. The agent version changes, and the [recommended memory settings](#recommended-settings) are added when they are missing.

| Install type | What the script does |
|--------------|----------------------|
| Kubernetes (`k8s/autoops_agent_deployment.yaml`) | Changes the image of the agent container and waits for the rollout. The manifest is not re-applied, so the Secret, your environment variables, your resources and volumes are untouched. |
| Docker / Podman | Recreates the container on the new image with the same environment, command, restart policy, memory and CPU limits, network, user, volumes, `--add-host` entries and published ports. The old container is kept as `<name>.autoops-backup`. |
| ECK (`AutoOpsAgentPolicy`) | Changes nothing. Prints the `kubectl patch` command that sets `spec.version`. |
| Helm | Changes nothing. Prints the `helm upgrade` command to use. |
| Linux service | Not supported yet. Re-run `linux/install_autoops.sh` with the new `--version`. |

The script never prints secret values: environment variables are listed by name only.

### Usage

Start with a dry run. It finds the install and shows what would change, without changing anything:

```sh
./upgrade/upgrade_autoops.sh --dry-run
```

Then upgrade. The script asks for confirmation unless you pass `--yes`:

```sh
./upgrade/upgrade_autoops.sh --version 9.4.9
```

If the new version does not become ready (Kubernetes) or does not stay up (Docker / Podman), the previous version is restored automatically. To go back yourself after a successful upgrade:

```sh
./upgrade/upgrade_autoops.sh --rollback
```

### Recommended settings

An upgrade also brings in the recommended memory settings when they are missing. The dry run lists exactly what would be added.

| Setting | What the script does |
|---------|----------------------|
| `GOMEMLIMIT` | Added at 80% of the agent's memory limit when the agent has a memory limit and no `GOMEMLIMIT`. A `GOMEMLIMIT` you set yourself is never changed. |
| Memory limit | Not set on its own, because the right size depends on the monitored cluster. Pass `--memory-limit <size>` (for example `512Mi`) to set it; `GOMEMLIMIT` then follows it. On Kubernetes the memory request is set to the same value. |
| Scrape periods, send queue | Not changed by the script. They are part of the configuration inside the agent image, so the new version brings its own. A configuration you mounted yourself is left as it is. |

These settings are also applied when the agent is already on the requested version, so you can run the script only to add them. Use `--no-defaults` to change the version and nothing else.

```sh
# Set a 512Mi memory limit and the matching GOMEMLIMIT while upgrading
./upgrade/upgrade_autoops.sh --version 9.4.9 --memory-limit 512Mi
```

A memory limit makes the container runtime restart the agent when it uses more than the limit, which shows as a short gap in the data. `GOMEMLIMIT` makes that less likely, because the agent frees memory before reaching the limit.

### Parameters

| Parameter | Applies to | Description |
|-----------|------------|-------------|
| `--version` | All | The version to upgrade to. Defaults to the version this repository installs. |
| `--target` | All | `auto` (default), `k8s`, `docker` or `podman`. Use it when more than one install is found. |
| `--dry-run` | All | Show the plan and exit. |
| `--rollback` | All | Go back to the version that ran before the last upgrade. |
| `--yes` | All | Do not ask for confirmation. Required when there is no terminal. |
| `--allow-downgrade` | All | Allow `--version` to be older than the installed version. |
| `--no-defaults` | All | Change the version only; do not add recommended settings. |
| `--memory-limit` | Kubernetes, Docker / Podman | Set this memory limit on the agent, for example `512Mi` or `1Gi`. |
| `--namespace`, `--all-namespaces` | Kubernetes | Where to look for the Deployment. Defaults to the current namespace. |
| `--context` | Kubernetes | The `kubectl` context to use. |
| `--deployment` | Kubernetes | The Deployment name, if it is not `autoops-elastic-agent`. |
| `--k8s-container` | Kubernetes | The container name, if it cannot be detected. |
| `--timeout` | Kubernetes | Seconds to wait for the rollout. Defaults to `300`. |
| `--container` | Docker / Podman | The container name, if it cannot be detected. |
| `--no-pull` | Docker / Podman | Do not pull the new image, for hosts where it was loaded by hand. |
| `--settle-seconds` | Docker / Podman | Seconds the new container must stay up. Defaults to `20`. |

### Exit Codes

| Code | Description |
|------|-------------|
| `0` | Upgraded, rolled back, or nothing to do |
| `1` | The upgrade failed; the previous version was restored when possible |
| `2` | Wrong usage, or a choice is needed (for example, more than one install was found) |
| `3` | An install was found that the script does not upgrade (ECK, Helm, Linux service) |
| `4` | No AutoOps agent install was found |

### Limits

- Docker / Podman options other than the ones listed above (for example `--cap-add`, `--log-driver` or labels) are not carried over. A container started with a custom `--entrypoint` is not upgraded. Check the command shown by `--dry-run` against your original one.
- Environment variable values that span several lines are not supported.
- Only one backup container is kept; a new upgrade replaces it.

# Diagnostic Tools

## Connectivity Check

The `tools/check_connectivity.sh` script verifies network connectivity and configuration before or after installation. It checks:

1. **Proxy Configuration** - Detects if HTTP_PROXY, HTTPS_PROXY, NO_PROXY, or other proxy variables are set
2. **Elasticsearch** - Tests connectivity to your Elasticsearch cluster with authentication
3. **Cloud API Connectivity** - Tests connectivity to the Elastic Cloud Connected Mode API
4. **OTel Endpoint** - Tests connectivity to the OpenTelemetry endpoint

### Usage

```sh
./tools/check_connectivity.sh
```

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AUTOOPS_ES_URL` | No | (skipped if unset) | Elasticsearch URL |
| `AUTOOPS_ES_USERNAME` | No | - | Elasticsearch username (for Basic auth) |
| `AUTOOPS_ES_PASSWORD` | No | - | Elasticsearch password (for Basic auth) |
| `AUTOOPS_ES_API_KEY` | No | - | Elasticsearch API key (for ApiKey auth) |
| `AUTOOPS_ES_CA` | No | - | Path to CA certificate file |
| `AUTOOPS_OTEL_URL` | No | `https://otel-auto-ops.ap-northeast-1.aws.svc.elastic.cloud` | OTel endpoint URL |
| `ELASTIC_CLOUD_CONNECTED_MODE_API_URL` | No | `https://api.elastic-cloud.com` | Cloud API URL |
| `ELASTIC_CLOUD_CONNECTED_MODE_API_KEY` | No | - | Cloud API key; sent as `Authorization: ApiKey` to the OTel endpoint and, when set alongside `AUTOOPS_ES_URL`, used to register the cluster with Elastic Cloud |

### Example with Elasticsearch

```sh
AUTOOPS_ES_URL="https://localhost:9200" \
AUTOOPS_ES_API_KEY="your-api-key" \
./tools/check_connectivity.sh
```

### Exit Codes

| Code | Description |
|------|-------------|
| `0` | All checks passed |
| `1` | One or more checks failed |
| `2` | One or more checks were skipped (e.g. `AUTOOPS_ES_URL` not set) |
