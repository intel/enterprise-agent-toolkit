# Decommission and redeploy

[← Docs index](../README.md)

Use this page when you want to remove the Agent Toolkit from a cluster and install it again, for example after a failed run, or when you want a different set of models. Teardown deletes the workloads, persistent volumes, and secrets for the target you name. That cannot be undone. The YAML under `env/<env>/` is **kept**, so your domain, TLS paths, and model flags survive and you do not have to re-type them.

## 1. Tear down

From the Stack Manager directory (see [which repository to start from](../overview/meet.md#which-repository-to-start-from)):

```bash
./stack-manager teardown agent-toolkit
```

That removes the Helm releases and namespaces the toolkit install owns (`redis`, `pgvector`, `agent-sandbox-system`, `mcp`, `ray-system`, and related inference pieces such as `litellm` and `langfuse` when they were brought up as dependencies). It also cleans images the install loaded onto the nodes.

To tear down **everything** the installer created, including Kubernetes itself:

```bash
./stack-manager teardown --all
```

Use `--all` only when you are ready to lose the cluster, not just the toolkit.

## 2. Install again

If you want a different layout, edit `env/local/*.yaml` first (domain, models, storage, and so on). Then:

```bash
./stack-manager install agent-toolkit
```

`install` is idempotent. Two useful checks after it finishes:

```bash
./stack-manager status
./stack-manager validate agent-toolkit
```

## Next steps

To stand the stack up again from scratch on one server, follow the [single-node quickstart](../getting-started/quickstart.md). The fields you can change before the next `install` are listed in [Configuration](../configuration/configuration.md). For several servers, use [multi-node deployment](multi-node.md). If install fails after redeploy, see [Troubleshooting](../faq-and-troubleshooting/troubleshooting.md).
