# Contributing to Intel® Agent Toolkit

Thanks for wanting to help. Small fixes are just as welcome as big features. Find what you want to do in the table below and start there.

## What do you want to do?

| I want to… | Do this | Where |
|---|---|---|
| Report a bug | Open an issue with the command you ran, what you expected, and the error you got | [Issues](https://github.com/intel/agent-toolkit/issues) |
| Suggest a feature or ask a question | Open an issue and tell us what you're trying to do | [Issues](https://github.com/intel/agent-toolkit/issues) |
| Report a security vulnerability | Please don't open a public issue. Report it privately instead | [Intel Security Center](https://www.intel.com/security) ([SECURITY.md](SECURITY.md)) |
| Fix a typo or improve a guide | Edit the Markdown file and open a pull request | `docs/` |
| Change a default setting | Update `config.yaml`, and the role defaults if the role reads that value | `config.yaml`, `roles/<component>/defaults/main.yaml` |
| Fix a bug in a component | Fix it in that component's Ansible role | `roles/<component>/tasks/` |
| Update a Helm chart | Edit the chart and run `helm lint` on it | `charts/<name>/` |
| Add a new component | See [Add a new component](#add-a-new-component) | `roles/`, `charts/`, `components.yaml`, `config.yaml` |

If you're not sure where your change fits, open an issue and ask. We're happy to point you in the right direction.

---

## Your first pull request

1. Fork the repository on GitHub, clone your fork, and make a branch off `main`:

   ```bash
   git clone https://github.com/<your-user>/agent-toolkit.git
   cd agent-toolkit
   git checkout -b fix/short-description
   ```

2. Make your change. Try to keep each pull request to one thing (one fix, one guide, one component). Smaller pull requests get reviewed a lot faster.

3. Run the [checks](#checks) that apply to what you changed. If you only touched docs, you can skip this.

4. Commit and push:

   ```bash
   git commit -am "Fix pgvector teardown when the namespace is already gone"
   git push origin fix/short-description
   ```

5. Open a pull request against `main` in `intel/agent-toolkit`. Tell us what you changed, why, and how you tested it.

The automated checks will run, and a maintainer will review it.

---

## Checks

Every pull request runs Ansible Lint, ShellCheck, Trivy, Checkov, Bandit, and Dependency Review. You'll save yourself a round trip if you run the relevant ones before you push:

```bash
# Ansible roles
pip install ansible-lint
ansible-lint --skip-list name,var-naming,fqcn,yaml,jinja,key-order roles/

# Helm charts
helm lint charts/<name>

# Shell scripts
shellcheck -x path/to/script.sh

# Any YAML you edited
python3 -c "import yaml; yaml.safe_load(open('components.yaml'))"
```

### Testing on a cluster

If you changed anything in `roles/` or `charts/`, please try it on a scratch cluster with [Toolkit Manager](https://github.com/intel/toolkit-manager). Point Toolkit Manager at your branch, then from the Toolkit Manager directory run:

```bash
./toolkit_manager.sh install agent-toolkit -- --check   # shows the install order without changing anything
./toolkit_manager.sh install <component>
./toolkit_manager.sh validate <component>
./toolkit_manager.sh install <component>                 # second run should report zero "changed"
./toolkit_manager.sh teardown <component>
./toolkit_manager.sh teardown <component>                # second run should still succeed
```

Running `install` and `teardown` twice is the part that catches the most bugs. Both have to be safe to re-run.

---

## Add a new component

A component is one service the toolkit installs on the cluster. Redis is a component, and so is the agent sandbox. These are the ones we have today:

| Component | What it does | On by default? |
|---|---|---|
| `redis_stack` | Short-term memory: session state and caches | Yes |
| `pgvector` | Long-term memory: PostgreSQL with vector search | Yes |
| `agent_sandbox` | Isolated pods where agent-generated code runs | Yes |
| `openshell` | NVIDIA OpenShell, for stricter, policy-enforced sandboxes on top of the agent sandbox | No |
| `kuberay` | A Ray cluster for distributed Python jobs | No |
| `keycloak_agent_config` | Keycloak setup for agents | Only when Keycloak is the gateway |

So adding a component means teaching the toolkit to install one more service, like another vector database. When you run an install, Toolkit Manager clones this repository under `ext/` and runs each enabled component in dependency order.

Each component is made of a few pieces:

| Piece | Where it goes | What it is |
|---|---|---|
| Role | `roles/<name>/` | The Ansible steps to install, check, and remove the service |
| Chart (optional) | `charts/<name>/` | The Helm chart the role deploys, committed in the repository |
| Settings | `config.yaml` | Defaults people can change, plus an on/off flag like `my_component_enabled: false` |
| Registry entry | `components.yaml` | Tells Toolkit Manager the component exists and what it depends on |
| Docs | `docs/<section>/`, `docs/README.md` | A short guide, linked from the docs index |

Copying an existing component, like `roles/pgvector/` and `charts/pgvector/`, is usually the fastest way to start.

### The role

```
roles/<name>/
├── tasks/
│   ├── main.yaml        Picks install, teardown, or validate
│   ├── install.yaml     Deploys the service. Must be safe to run twice
│   ├── teardown.yaml    Removes what install created. Must succeed if it's already gone
│   └── validate.yaml    Checks the service is healthy. Never changes anything
├── defaults/main.yaml   Every variable the role uses, with a default that works
└── meta/main.yaml       Metadata only. Don't add dependencies here
```

`tasks/main.yaml` is the same in every role:

```yaml
---
- name: "<name> | Dispatch action: {{ component_action }}"
  ansible.builtin.include_tasks: "{{ component_action }}.yaml"
```

Toolkit Manager sets `component_action` to `install`, `teardown`, or `validate`. It also passes `env_dir`, `env_name`, and `kubernetes_kubeconfig`.

### The registry entry

```yaml
components:
  - name: my_component
    layer: agent-toolkit
    enabled: "{{ my_component_enabled | default(true) | bool }}"
    depends_on: [redis_stack]
```

A few things trip people up here:

- `name` has to match the folder name under `roles/`.
- `depends_on` only lists components from this repository. You don't need to list Kubernetes or model serving; those are always installed first.
- `enabled` is evaluated before the role's defaults are loaded, so it needs its own `| default(...)` and should end with `| bool`.

### The chart

We commit charts into `charts/<name>/` so an install never has to reach an outside Helm repository. If your chart has subcharts, commit those too (as `.tgz` files under `charts/<name>/charts/`), or remove the ones you don't use. Otherwise `helm install` fails. In the role, refer to the chart with a path relative to `role_path`.

### The settings

When someone runs `init agent-toolkit`, `config.yaml` gets copied to `env/<env>/config.agent-toolkit.yaml`, and that copy is what they edit. So anything you want people to be able to change belongs in `config.yaml`.

---

## A few house rules

- Use the `kubernetes.core.k8s` and `kubernetes.core.helm` modules rather than calling `kubectl` or `helm` from a shell task.
- Keep variables flat, like `my_component_replicas`. Config files are merged, and a nested dictionary in one file overwrites the whole dictionary from another.
- Start variable names with your component name. Every component Toolkit Manager installs shares the same variable namespace.
- Never commit secrets or anything under `env/`. Generate secrets during install, or read them from a Kubernetes Secret.
- Keep LF line endings. `.gitattributes` handles this, but some copy tools sneak in CRLF, which breaks shell scripts on Linux.
- If your change affects a command, a setting, or a default, update the guide that talks about it.

---

## License

This project is licensed under the [Apache License, Version 2.0](LICENSE). By contributing, you agree that your contributions are licensed under the same terms.
