# Agentic AI Plugin - Quick Start Guide

## Overview

The **Agentic AI Plugin** provides a visual platform for building AI agents, multi-agent systems, and intelligent workflows. The current implementation uses **Flowise**, an open-source drag-and-drop tool for creating conversational AI, RAG applications, and workflow automation without coding.

**About Flowise:** [Official Documentation](https://docs.flowiseai.com/) | [GitHub](https://github.com/FlowiseAI/Flowise)

**Key Features:**
- Visual workflow builder with drag-and-drop interface
- Pre-built agent templates and marketplace
- Multi-agent collaboration support
- Integration with deployed LLM models
- RAG (Retrieval Augmented Generation) support
- API integration for external services

---

## Deployment

### Prerequisites
- Intel® AI for Enterprise Inference automation deployed
- Kubernetes cluster with ingress controller
- TLS certificate with Flowise subdomain in SANs (flowise-<your-domain>)

### Step 1: Enable Plugin

Edit the main configuration:
```bash
vim core/inventory/agentic-config.cfg
```

Set:
```properties
deploy_agenticai_plugin=on
```

### Step 2: Deploy

```bash
cd core
bash inference-stack-deploy.sh
```

Select: `1) Provision Enterprise Inference Cluster`

### Step 3: Verify

```bash
kubectl get pods -n flowise
```

Expected output:
```
NAME                                 READY   STATUS    RESTARTS   AGE
flowise-xxxxx                        1/1     Running   0          5m
flowise-postgresql-0                 1/1     Running   0          5m
flowise-redis-master-0               1/1     Running   0          5m
flowise-worker-xxxxx                 1/1     Running   0          5m
```

Two Ingress objects are expected — the site itself, and the source-restricted rule that
protects account creation:

```bash
kubectl get ingress -n flowise
```

```
NAME                    CLASS   HOSTS                    PORTS
flowise-account-setup   nginx   flowise-<your-domain>    80, 443
flowise-root            nginx   flowise-<your-domain>    80, 443
```

---

## Initial Setup

### Accessing the Platform

Open in browser:
```
https://flowise-<your-domain>
```

> **Note:** The subdomain is "flowise" as this is the current implementation. Future versions may support custom subdomains.

### Step 4: Create the Administrator Account

Flowise creates its first organization owner through an **unauthenticated** request, so
whoever submits the Setup Account page first becomes the sole owner — everyone after them
is rejected with `You can only have one organization`. The deployment therefore publishes
that one endpoint (`POST /api/v1/account/register`) on a source-restricted Ingress rule,
and by default it admits nothing from the network.

So create the owner once over a port-forward, which reaches the pod through the API server
and never passes the Ingress rule at all:

```bash
kubectl port-forward -n flowise svc/flowise 3000:3000
```

Leave that running and open **http://localhost:3000**.

Everything else — login and all normal use — happens at `https://flowise-<your-domain>`,
which is live from the first deployment. Only account creation is restricted.

> **Prefer to do setup in the browser at the domain instead?** Set your network in
> `plugins/agenticai/vars/agenticai-plugin-vars.yml` and redeploy the plugin:
> ```yaml
> agenticai_setup_source_ranges: "192.0.2.0/24"   # replace with your own network
> ```
> Comma-separate multiple ranges. Account creation is then accepted from those networks at
> `https://flowise-<your-domain>` and answered `403` everywhere else.

### First Time Setup (Account Creation)

You'll see the **Setup Account** page:

1. **Administrator Name:** Your display name (e.g., "John Doe")
2. **Administrator Email:** Valid email address - **this becomes your login ID**
3. **Password:** Must contain:
   - At least 8 characters
   - One lowercase letter
   - One uppercase letter
   - One digit
   - One special character
4. **Confirm Password:** Re-enter password
5. Click **"Sign Up"**

> **Important:** Account setup is local to your server. No external connections are made. Your data stays on your infrastructure.

### Subsequent Logins

Stop the port-forward and use the Ingress from here on:
```
https://flowise-<your-domain>
```
- **Email:** The email you registered
- **Password:** Your chosen password

Login is not source-restricted — only account creation is.

### Optional: close the registration endpoint

Once the owner account exists, Flowise itself rejects every further call to
`/api/v1/account/register` with `You can only have one organization`, so nothing more is
strictly needed. For defence in depth you can drop the endpoint from Flowise's public
whitelist entirely — set this in `plugins/agenticai/vars/agenticai-plugin-vars.yml` and
redeploy the plugin:

```yaml
agenticai_lock_registration: true
```

The endpoint then answers `401` to every caller, from any source and including over a
port-forward. This costs no functionality in open-source mode — but do it only *after* the
administrator account exists, or there will be no way to create one.

> ⚠ **Leave this off if you ever configure `FLOWISE_EE_LICENSE_KEY`** (Flowise
> Enterprise). Enterprise mode reuses that same endpoint to let **invited** users complete
> their signup with an invite code, so locking it would block multi-user onboarding.

---

## Using the Platform

### Add a Credential

Flowise stores API keys and credentials that can be reused by workflow nodes. Credentials are encrypted in the database.

1. In the left sidebar, click **Credentials**
2. Click **Add Credential**
3. Choose **OpenAI API**
4. Provide:
   - **Credential Name**: e.g., `InternalLLM`
   - **API Key**: you can enter `sk-dummy` (for internal models)
5. Click **Save**

⚠️ This UI uses OpenAI API credential type because Flowise nodes expect this format; for internal models there may not be a real API key.

### Connecting to Deployed Models

The Agentic AI Plugin is designed to work seamlessly with models deployed on the same Kubernetes cluster, avoiding external network calls for better performance and security.

#### Using Locally Deployed Models

**For models deployed on the same cluster:**

Since your LLM models are deployed within the same Kubernetes cluster as Flowise, use internal service endpoints for optimal performance:

1. Add **"Custom Chat Model"** or **"OpenAI Compatible"** node to your workflow
2. Configure with Kubernetes internal service endpoint:
   - **Base URL/Endpoint:** `http://<service-name>.<namespace>.svc.cluster.local:<port>/v1`
     - Example: `http://llama-2-7b-service.default.svc.cluster.local:8000/v1`
   - **Model Name/ID:** Your model identifier
     - Example: `meta-llama/Llama-2-7b-chat-hf`
   - **API Key:** `sk-dummy` (use APIKey from GenAI gateway)

**Find your deployed model services:**
```bash
kubectl get svc | grep -E "vllm"
```

**Benefits of using internal endpoints:**
- ✅ **Faster:** No network egress/ingress - direct cluster networking
- ✅ **Secure:** Traffic stays within the cluster
- ✅ **No External Costs:** No internet bandwidth charges
- ✅ **Lower Latency:** Milliseconds vs. seconds

#### Using External/Cloud Models (Optional)

**For models hosted externally or in the cloud:**

If you need to use OpenAI, Anthropic, or other external models:

1. Add the appropriate chat model node (e.g., "ChatOpenAI", "ChatAnthropic")
2. Configure:
   - **Endpoint:** Cloud provider endpoint (e.g., `https://api.openai.com/v1`)
   - **Model ID:** Cloud model name (e.g., `gpt-4`, `claude-3-opus`)
   - **API Key:** Your cloud provider API key

---

## Administration

### Common Commands

**View Logs:**
```bash
kubectl logs -n flowise -l app.kubernetes.io/name=flowise -f
kubectl logs -n flowise -l app=flowise-worker -f
```

**Check Status:**
```bash
kubectl get pods,svc,ingress -n flowise
```

**Database Backup:**
```bash
kubectl exec -n flowise flowise-postgresql-0 -- pg_dump -U flowise flowise > flowise-backup.sql
```

**Restart Platform:**
```bash
kubectl rollout restart deployment/flowise -n flowise
```

**Scale Workers:**
```bash
kubectl scale deployment flowise-worker -n flowise --replicas=5
```

### Database Passwords

Backend passwords (PostgreSQL, Redis) are auto-generated during deployment and stored in:
```
core/kubespray/config/vault.yml
```

Variables:
- `agenticai_postgres_password`
- `agenticai_redis_password`

> **Note:** User login passwords are set by users themselves during account creation, not from vault.

---

## Troubleshooting

### Cannot Access UI

**Check ingress:**
```bash
kubectl get ingress -n flowise
kubectl describe ingress flowise -n flowise
```

**Verify certificate includes subdomain:**
```bash
openssl s_client -connect flowise-<your-domain>:443 -servername flowise-<your-domain> < /dev/null | openssl x509 -noout -text | grep DNS
```

### "Setup Account" Returns 403 Forbidden

Expected when going through the Ingress with the default settings — use the port-forward in
Step 4 instead. If you *have* set `agenticai_setup_source_ranges`, your client address is
not inside it. Check what the ingress controller is allowing and what it sees as your
source address:

```bash
kubectl get ingress flowise-account-setup -n flowise \
  -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/whitelist-source-range}{"\n"}'

kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50 \
  | grep 'account/register'
```

Add your range in `plugins/agenticai/vars/agenticai-plugin-vars.yml` and redeploy the
plugin, or patch it directly for a one-off:

```bash
kubectl annotate ingress flowise-account-setup -n flowise --overwrite \
  nginx.ingress.kubernetes.io/whitelist-source-range="192.0.2.0/24,198.51.100.9/32"
```

> If the logged source address is a cluster node IP rather than your workstation, an
> upstream load balancer is SNAT-ing the traffic. Enable
> `controller.config.use-forwarded-headers` on ingress-nginx so the real client address is
> used, or list the load balancer's ranges instead.

### "Setup Account" Returns 401 Unauthorized

`agenticai_lock_registration` is on, which removes the endpoint from Flowise's public
whitelist. That is only meant to be enabled *after* the owner account exists — set it back
to `false` in `plugins/agenticai/vars/agenticai-plugin-vars.yml` and redeploy if you still
need to create the administrator.

### Pods Not Starting

```bash
kubectl describe pod -n flowise <pod-name>
kubectl logs -n flowise <pod-name> --previous
```

### Database Connection Issues

```bash
# Test connectivity from Flowise pod
kubectl exec -n flowise <flowise-pod> -- nc -zv flowise-postgresql 5432

# Check PostgreSQL logs
kubectl logs -n flowise flowise-postgresql-0
```

---

## Additional Resources

- Official Documentation: https://docs.flowiseai.com/
- GitHub Repository: https://github.com/FlowiseAI/Flowise
- Community Discord: https://discord.gg/jbaHfsRVBW
- Example Workflows: https://docs.flowiseai.com/use-cases

---
