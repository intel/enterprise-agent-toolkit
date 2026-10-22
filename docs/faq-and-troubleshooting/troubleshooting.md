# Troubleshooting

[← Docs index](../README.md)

Problems you hit while installing or calling the API. If the error is specific to one component (sandbox, guardrails, Docker Compose), jump to that guide at the bottom of the page. For “where do I run the installer?” and similar, see the [FAQ](frequently-asked-questions.md).

## Installer and Kubernetes

| What you see | What to try |
|---|---|
| `stack-manager: No such file or directory` | You are in this toolkit repo. `cd` to Stack Manager and run the commands from that root. It installs, updates, and tears the toolkit down. [Meet the Agent Toolkit](../overview/meet.md) · [FAQ](frequently-asked-questions.md#where-installer) |
| SSH connection refused during Kubespray | Check inventory IPs and the key path in `env/local/inventory/hosts.yaml`. Confirm passwordless SSH from the installer host. [Prerequisites](../getting-started/prerequisites.md#1-ssh-keys) |
| Node `NotReady` | On that node, run `systemctl status kubelet` and inspect the kubelet journal. |
| Pods stuck `Pending` | `kubectl describe pod -n <ns> <pod>` and `kubectl describe node`: usually CPU, RAM, or a taint that blocks scheduling. |
| vLLM stays `ContainerCreating` / `Init` | Weights are still downloading. 10–15 minutes is normal. Follow progress with `kubectl logs -n <ns> <pod>`. |
| `pull access denied` | Docker Hub / registry login is missing, or the image name does not exist in that registry. |
| Hugging Face `401` | The model is gated. Create a Read token, accept the license on Hugging Face, and `export HF_TOKEN=...` in the same shell as `install`. |

## Gateway and API

| What you see | What to try |
|---|---|
| `curl` TLS error | Self-signed cert: add `-k`. The hostname must match `base_domain_name` and `/etc/hosts`. [Prerequisites](../getting-started/prerequisites.md#2-dns-and-tls) |
| `401` from `/v1/models` | Wrong or missing `Authorization: Bearer`. Get the key from secret `litellm-master-key` in namespace `litellm`. |
| Empty model list | Set `llm_services_deploy_models: true` and `autodeploy: true` on at least one catalog entry, then re-run `install`. |
| Chat hangs / no tokens | `kubectl get pods -A`: is the model pod Running? Check the trace UI at `https://trace-<base_domain_name>`. |
| `finish_reason: content_filter` with HTTP 200 | The guardrail blocked the prompt. That is not a transport error. [Guardrails](../configuration/guardrails.md) |

## Redis / pgvector / sandbox

| What you see | What to try |
|---|---|
| Redis `WRONGPASS` | The URL must be `redis://default:<password>@...`. Read `REDIS_URL` from the Kubernetes secret instead of guessing the password. |
| Cannot reach Redis from outside the cluster | Redis is ClusterIP on purpose. Use `kubectl port-forward`; do not switch the Service to NodePort. |
| Sandbox `/healthz` fails | `kubectl get pods -n agent-sandbox-system`. Port-forward `sandbox-router-svc`. [Agent sandbox](../reference/agent-sandbox.md) |

## Docker Compose

See the table in [Docker](../deployment/docker.md#troubleshooting).

## Next steps

If the table does not match what you see, the [FAQ](frequently-asked-questions.md) covers the common “am I in the right repo?” questions. The [single-node quickstart](../getting-started/quickstart.md) and [multi-node](../deployment/multi-node.md) guides have the expected healthy state. Guardrail and sandbox specifics are in [Guardrails](../configuration/guardrails.md) and [Agent sandbox](../reference/agent-sandbox.md).
