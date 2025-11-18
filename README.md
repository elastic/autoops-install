# autoops-install

Install scripts to simplify the installation of AutoOps with your Self-Managed clusters.

# Kubernetes Installation

Instructions for the Kubernetes installation are provided by the AutoOps Installation Wizard. However, examples are shown below for posterity.

Use the `k8s/autoops_agent_deployment.yaml` deployment configuration to install a new agent in your Kubernetes cluster.

| Parameter | Optional | Description |
|-----------|----------|----------|
| `autoops-token` | No  | The AutoOps Token.  |
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
  --from-literal=autoops-token="<Provided by AutoOps installation wizard>" \
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
  --from-literal=autoops-token="<Provided by AutoOps installation wizard>" \
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
| `token`     | No  | The AutoOps Token.  |
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
  --token "<Provided by AutoOps installation wizard>" \
  --otel-endpoint "<Provided by AutoOps installation wizard>" \
  --ccm-api-key "<Provided by AutoOps installation wizard>" \
  --ccm-api-url "<Provided by AutoOps installation wizard if needed>" \
  --temp-resource-id "<Provided by AutoOps installation wizard>" \
  --es-endpoint "<your-es-url>" \
  --es-username "<your-es-user>" \
  --es-password "<your-es-pass>" \
--es-password "<your-es-pass>"
```

### Installation with Elasticsearch API Key

```sh
./install_autoops.sh \
  --token "<Provided by AutoOps installation wizard>" \
  --otel-endpoint "<Provided by AutoOps installation wizard>" \
  --ccm-api-key "<Provided by AutoOps installation wizard>" \
  --ccm-api-url "<Provided by AutoOps installation wizard if needed>" \
  --temp-resource-id "<Provided by AutoOps installation wizard>" \
  --es-endpoint "<your-es-url>" \
  --es-api-key "<your-es-api-key>" \
--es-api-key "<your-es-api-key>"
```
