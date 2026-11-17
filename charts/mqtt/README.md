# mqtt (comqtt broker)

Deploys [comqtt](https://github.com/wind-c/comqtt) (`ghcr.io/wind-c/comqtt`) as the
Rekognitor MQTT broker. Replaces the previous `mochimqtt/server` deployment.

`rekognitor-rtsp-stream` publishes camera detections to `cameras/<cameraID>` over TCP `1883`.

## Listeners

| Port | Purpose | Service |
| ---- | ------- | ------- |
| 1883 | MQTT / TCP | `mqtt` (LoadBalancer) |
| 1882 | MQTT over WebSocket | `mqtt` (LoadBalancer) |
| 8080 | REST stats + dashboard UI (`/dashboard/`) | `mqtt-dashboard` (ClusterIP by default) |

Auth is anonymous (`auth.way: 0`) and storage is in-memory (`storage-way: 0`),
matching the old mochi setup. The full `mqtt.options.capabilities` block is set
explicitly in the ConfigMap — comqtt unmarshals config into a zero-value struct,
so leaving it out would silently disable wildcard subscriptions / QoS / retain.

## Dashboard

Enabled by default (`dashboard.enabled: true`). Default login: **admin / rekognitor-admin**.

The users file is mounted read-only, so change the password declaratively:

```bash
# generate a bcrypt hash for the new password
htpasswd -bnBC 10 "" 'NEWPASS' | tr -d ':\n' | sed 's/^\$2y/\$2a/'
# put it in values.yaml -> dashboard.adminPasswordHash, then helm upgrade
```

Also change `dashboard.authSecret` (signs session cookies) before exposing the UI.

The dashboard service is `ClusterIP` by default. To view it:

```bash
kubectl port-forward svc/mqtt-dashboard 8080:8080
# http://localhost:8080/dashboard/
```

Set `dashboard.service.type: NodePort` (or `LoadBalancer`) to expose it directly.

## External access (outside k3s and WSL)

This cluster runs in **k3s inside WSL2 with `networkingMode=mirrored`** — WSL shares
the Windows host's LAN IP (e.g. `192.168.1.10`), so k3s `LoadBalancer` services
(served by klipper/ServiceLB) bind the node and are reachable directly:

- **From the WSL host / Windows:** `localhost:1883` (mirrored loopback) and `<host-LAN-IP>:1883`.
- **From other LAN machines:** `<host-LAN-IP>:1883` — but Windows blocks inbound by
  default. Run the helper once, elevated, on Windows:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\allow-wsl-inbound.ps1
  ```

  It adds the host firewall rule *and* the Hyper-V firewall rule that mirrored-mode
  WSL traffic needs.

Verify:

```bash
kubectl get svc mqtt -o wide            # EXTERNAL-IP should be the node/host IP
mosquitto_sub -h 192.168.1.10 -p 1883 -t 'cameras/#' -v
```

NodePort fallback (if you prefer not to rely on the LoadBalancer): `<node-IP>:31883`.
