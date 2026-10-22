# Running behind a corporate proxy

If you are working in a corporate environment where internet access is routed through a proxy, you need to configure the appropriate proxy settings for tools and scripts to work correctly.

This is supported using proxy configuration through agentic-config.cfg file

---

## Configuration Steps

1. Open the configuration file:

   ```bash
   agentic-config.cfg
   ```

2. Add the following three environment variables with your proxy details:

   ```bash
   http_proxy="http://<YOUR_PROXY_SERVER>:<PORT>"
   https_proxy="http://<YOUR_PROXY_SERVER>:<PORT>"
   no_proxy="localhost,127.0.0.1,.<YOUR_COMPANY>.com,10.96.0.0/12,192.168.0.0/16,10.233.0.0/16,.svc,.svc.cluster.local"
   ```

   > **Note:** Make sure to include any internal domains or IPs in `no_proxy` that should bypass the proxy. `10.96.0.0/12` is the range for Kubernetes services using standard tools such as `kubeadm`. `192.168.0.0/16` are standard IPs for personal computers. `10.233.0.0/16` is a standard IP address for clusters deployed using Kubespray.

To unset proxy from apt, please remove proxy configurations from below file
sudo nano  /etc/apt/apt.conf
