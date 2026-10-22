# Build your first agent

[← Docs index](../README.md)

This guide builds a LangChain agent that calls the model through the Agent Toolkit gateway and uses a tool. When it finishes, you have a working agent script, and Langfuse shows each model request the agent made.

Complete the [single-node quickstart](quickstart.md) first. The agent uses the same gateway, model, and master key.

## Before you begin

| Requirement | Detail |
|---|---|
| A working install | The quickstart test returns a chat completion. |
| `auth_provider: litellm` | LiteLLM provides the API key and sends gateway traces to Langfuse. |
| A model with tool calling | The examples use `Qwen/Qwen3-4B-Instruct-2507`, the quickstart model. |
| Python 3.10 or later | On the install host, or on a machine whose `/etc/hosts` maps the gateway hostnames to the host's IP. |

## 1. Set up the environment

Create a virtual environment and install the packages:

```bash
python3 -m venv ~/first-agent && source ~/first-agent/bin/activate
pip install "langchain>=1.0,<2" "langchain-openai>=1.0,<2"
```

Set the connection variables. Run the `kubectl` and `cp` commands from the Stack Manager directory:

```bash
export AGENT_TOOLKIT_BASE_URL=https://api.example.com/v1        # https://<base_domain_name>/v1

export LITELLM_MASTER_KEY=$(kubectl get secret litellm-master-key -n litellm \
  -o jsonpath='{.data.master_key}' | base64 -d)

cp env/local/logs/ai-solutions-ca.crt ~/first-agent/ca.crt
export SSL_CERT_FILE=~/first-agent/ca.crt
```

| Variable | Purpose |
|---|---|
| `AGENT_TOOLKIT_BASE_URL` | The OpenAI-compatible endpoint of the gateway. |
| `LITELLM_MASTER_KEY` | The API key the agent sends to the gateway. |
| `SSL_CERT_FILE` | Trusts the root CA the installer generated (`gateway_tls_mode: selfsigned`). |

Set `SSL_CERT_FILE` **after** `pip install`. It replaces the default trust store, so `pip` can no longer reach PyPI while it is set. With a CA-issued certificate, omit it.

## 2. Write the agent

Save as `agent.py`:

```python
import os

from langchain.agents import create_agent
from langchain_core.tools import tool
from langchain_openai import ChatOpenAI


@tool
def multiply(a: float, b: float) -> float:
    """Multiply two numbers."""
    return a * b


llm = ChatOpenAI(
    model="Qwen/Qwen3-4B-Instruct-2507",
    base_url=os.environ["AGENT_TOOLKIT_BASE_URL"],
    api_key=os.environ["LITELLM_MASTER_KEY"],
    temperature=0,
)

agent = create_agent(
    model=llm,
    tools=[multiply],
    system_prompt="You are a concise assistant. Use the multiply tool for arithmetic.",
)

result = agent.invoke(
    {"messages": [{"role": "user", "content": "What is 23.5 multiplied by 4?"}]}
)
print(result["messages"][-1].content)
```

| Part | Purpose |
|---|---|
| `ChatOpenAI` | The LangChain OpenAI client. `base_url` and `api_key` point it at the gateway instead of OpenAI. No other change is needed. |
| `@tool` | Turns a Python function into a tool. The docstring is the description the model reads to decide when to call it. |
| `create_agent` | Runs the agent loop: the model requests a tool, LangChain runs it, and the result goes back to the model until it returns a final answer. |

## 3. Run it

```bash
python agent.py
```

The output is the final answer, for example `23.5 multiplied by 4 is 94.`. The model chose to call `multiply`, LangChain ran it, and the model wrote the answer from the result.

## 4. Check the traces in Langfuse

The gateway sends every model request to Langfuse automatically. No code or configuration is needed.

Open `https://trace-<base_domain_name>` (for example `https://trace-api.example.com`) and select **Traces**. Each run of `agent.py` produces one trace per model request, usually two:

1. The request in which the model asks to call `multiply` with `a: 23.5, b: 4`.
2. The request that includes the tool result, `94.0`, in which the model writes the final answer.

Each trace shows the prompt, the completion, token counts, latency, and the model that served the request.

## Troubleshooting

| Symptom | Resolution |
|---|---|
| `SSL: CERTIFICATE_VERIFY_FAILED` | `SSL_CERT_FILE` is not set in this shell, or points to the wrong file. Repeat the export commands from step 1. |
| `pip` fails with a certificate error | `SSL_CERT_FILE` is set. Run `unset SSL_CERT_FILE`, install, then export it again. |
| `Connection error` or `Could not resolve host` | The gateway hostname does not resolve on this machine. Add it to `/etc/hosts` as in the quickstart. |
| `401` from the gateway | `LITELLM_MASTER_KEY` is not set in this shell. Repeat the export command. |
| Langfuse shows one trace instead of two | The model answered without calling the tool. Run again, or ask for a calculation the model is less likely to answer directly. |
| `tool_choice` or tool-call errors from the gateway | The served model is not configured for tool calling. Use a model that supports it. |

## Next steps

- Connect the agent to session memory, the vector store, or the code sandbox using the URLs in the [backend connection reference](../reference/backend-connections.md).
- Screen prompts before they reach the model with [Guardrails](../configuration/guardrails.md).
- Send the agent to several models through one name with [Routing](../configuration/routing.md).
- Serve other models by editing `models.yaml`, described in [Configuration](../configuration/configuration.md).
- Terms: [glossary](../reference/glossary.md). Failures: [Troubleshooting](../faq-and-troubleshooting/troubleshooting.md).
