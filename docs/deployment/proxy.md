# Running behind a corporate proxy

[← Docs index](../README.md)

If this host reaches the internet only through an HTTP proxy, put the proxy URL in the generated YAML so the installer can copy it into every workload that needs outbound access: image pulls, Hugging Face weight downloads, and LiteLLM bootstrap. Without these keys, `install` will hang or fail the first time a pod tries to leave the cluster.

## 1. Set the three keys

After `init`, edit `env/local/global_config.yaml`:

```yaml
http_proxy: "http://your.proxy.server:port"
https_proxy: "http://your.proxy.server:port"
no_proxy: "localhost,127.0.0.1,.svc,.cluster.local,<pod-cidr>,<service-cidr>"
```

`no_proxy` must include `.svc` and `.cluster.local` so pod-to-pod traffic does not go through the proxy. Add your company domains and the cluster pod/service CIDRs.

## Example

```yaml
http_proxy: "http://proxy.corporate.com:8080"
https_proxy: "http://proxy.corporate.com:8080"
no_proxy: "localhost,127.0.0.1,.mycompany.com,.svc,.cluster.local,10.233.64.0/18,10.233.0.0/18"
```

Then run `./stack-manager install agent-toolkit` as usual. The installer reads these keys from `global_config.yaml`; you do not also need to export them in the shell unless a tool you run by hand (for example `helm` or `curl`) needs the same proxy.

## apt and Docker

If `apt-get` hangs, the host itself may still be using a proxy in `/etc/apt/apt.conf`. Remove or fix those `Acquire::http::Proxy` lines so package installs can reach your mirror. Docker Engine has its own proxy config if image pulls fail after the YAML above is set.

## Next steps

Finish [Prerequisites](../getting-started/prerequisites.md) if you have not already, then continue with the [single-node quickstart](../getting-started/quickstart.md) or [Configuration](../configuration/configuration.md) if you still need to set domain and TLS. Proxy keys live in `global_config.yaml` with the other cluster-wide settings. If image pulls still fail, see [Troubleshooting](../faq-and-troubleshooting/troubleshooting.md).
