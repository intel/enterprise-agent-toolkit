# Frequently Asked Questions

[← Docs index](../README.md)

Short answers to the questions that come up most often. Installation steps stay in the [single-node quickstart](../getting-started/quickstart.md); this page does not repeat them.

**On this page**

- [What is the Agent Toolkit?](#what-is)
- [How is this different from LangGraph or CrewAI?](#vs-frameworks)
- [Do I need a GPU?](#gpu)
- [Can I use OpenAI, Anthropic, or Gemini?](#cloud-models)
- [Where do I run the installer?](#where-installer)
- [Which YAML files do I edit?](#which-yaml)
- [Do I need a Hugging Face token?](#hf-token)
- [How do I know it is up?](#is-it-up)
- [Where is the API key?](#api-key)
- [Can I replace Redis / LiteLLM / the sandbox?](#replace)
- [Is this for on-prem or air-gapped sites?](#on-prem)
- [What license is it under?](#license)

<a id="what-is"></a>

## What is the Agent Toolkit?

Intel® Agent Toolkit is the infrastructure for production agents. [Stack Manager](../overview/meet.md#which-repository-to-start-from) installs, updates, and tears it down. A model endpoint is not enough for production agents: they also need Redis for short-term memory, PostgreSQL with pgvector for long-term memory, a code sandbox, MCP tool templates, and optionally Ray. Applications still call an OpenAI-compatible HTTPS API; only the base URL and key change.

See [Meet the Agent Toolkit](../overview/meet.md) for what install brings up and a request-flow diagram.

<a id="vs-frameworks"></a>

## How is this different from LangGraph or CrewAI?

LangGraph and CrewAI are **orchestration** libraries: they decide when to call the model and which tool to invoke. This toolkit is the **infrastructure** those libraries use: the gateway, model serving, memory, and sandbox. Run LangGraph or CrewAI **on top of** this stack by pointing the framework at `https://<base_domain_name>/v1`.

<a id="gpu"></a>

## Do I need a GPU?

No. This release runs models on Intel® CPUs. You can add a cloud or GPU endpoint on the same LiteLLM gateway later. It is optional.

<a id="cloud-models"></a>

## Can I use OpenAI, Anthropic, or Gemini?

Yes. LiteLLM can proxy those providers next to the local vLLM models. Your application still uses one base URL. How to add a provider is in LiteLLM's own docs; local models are the default this installer deploys.

<a id="where-installer"></a>

## Where do I run the installer?

From the Stack Manager directory. That repository contains `./stack-manager`. `init agent-toolkit` clones this repository under `ext/`. Stack Manager installs, updates, and tears the toolkit down. See [Meet the Agent Toolkit](../overview/meet.md). Other software the same manager can install is listed under [Deploy](../README.md#deploy).

<a id="which-yaml"></a>

## Which YAML files do I edit?

Only the copies under `env/local/` (or `env/<name>/`) after `init`. Typical files:

| File | When you touch it |
|---|---|
| `global_config.yaml` | Domain, TLS, auth, storage, proxy |
| `config.inference.yaml` | Turn model serving on |
| `models.yaml` | Which models to start (`autodeploy: true`) |
| `config.agent-toolkit.yaml` | Optional KubeRay; namespaces |

Details: [Configuration](../configuration/configuration.md).

<a id="hf-token"></a>

## Do I need a Hugging Face token?

Only for **gated** models (Llama, Gemma). The default quickstart model `Qwen/Qwen3-4B-Instruct-2507` is ungated. If you need a token:

```bash
export HF_TOKEN=hf_...
```

Do that in the same shell as `install`. Create a Read token and accept the model license on Hugging Face first.

<a id="is-it-up"></a>

## How do I know it is up?

```bash
kubectl get nodes          # Ready
kubectl get pods -A        # Running (the vLLM pod can stay ContainerCreating while weights download)
```

Then `curl` `/v1/models` with the master key. If that lists your model, send `/v1/chat/completions`. Commands: [Single-node quickstart](../getting-started/quickstart.md#5-confirm-it-works).

<a id="api-key"></a>

## Where is the API key?

```bash
kubectl get secret litellm-master-key -n litellm \
  -o jsonpath='{.data.master_key}' | base64 -d
```

That is the LiteLLM master key. It is created at install. Do not commit it.

<a id="replace"></a>

## Can I replace Redis / LiteLLM / the sandbox?

Yes, in principle. Each capability (gateway, memory, sandbox) has a default implementation and a defined job, so a later swap does not require rebuilding the rest of the stack. On day one, use the defaults. Swapping a provider is not required to get a working agent.

<a id="on-prem"></a>

## Is this for on-prem or air-gapped sites?

On-prem Intel® hardware is the target. The first install needs internet access to pull container images and Helm charts. A fully air-gapped site (pre-loaded images, no outbound network) is a follow-on operations topic, not the quickstart.

<a id="license"></a>

## What license is it under?

Apache License 2.0 for this repository. Models have their own licenses on Hugging Face. Gated models require you to accept those terms before you can download weights.

## Related pages

- [Meet the Agent Toolkit](../overview/meet.md): what the toolkit is
- [Docs index](../README.md): every guide in this cluster
- [Single-node quickstart](../getting-started/quickstart.md): first install
- [Configuration](../configuration/configuration.md): YAML under `env/local/`
- [Glossary](../reference/glossary.md): terms used in the answers above
- [Troubleshooting](troubleshooting.md): installer and API failures
