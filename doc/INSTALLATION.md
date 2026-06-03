Installation
=============


### Install from local clone

1. **Clone the repo**

```bash
git clone https://github.com/cetic/helm-nifi.git
cd helm-nifi
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add dysnix https://dysnix.github.io/charts/
helm repo update
helm dep up
```
2. **Set a sensitiveKey**

In 1.23.2 version, Nifi needs a sensitiveKey to encrypt sensitive information. This key can be setted in the `values.yaml` file:

````
properties:
  sensitiveKey: changeMechangeMe
````

3. **Configure a user authentication**

This helm chart provides three types of authentication: Single User, LDAP and OIDC.

You can find how to configure these authentications on this [page](doc/USERMANAGER.md).

4. **Install Nifi**

To install Nifi, run this command:

```bash
helm install nifi .
```
5. **Access Nifi**

If you let the Nifi service in ClusterIP mode, you cannot reach Nifi from the outside of the cluster. To fix that, you have to make a port forwarding to access Nifi from the localhost. To do that, run the command below:

````
kubectl port-forward service/nifi 8443:8443
````

Now you can access to Nifi with a browser by typing the address: `https://localhost:8443`

---

## NiFiSync — syncPaths Configuration

`NiFiSync.syncPaths` defines a list of paths that are synced from S3 (via the s3sync sidecars) into the NiFi pod. Each path has a `pathType` that controls how it is handled:

| `pathType` | Description |
|---|---|
| `fs` | Remote S3 path is mirrored to `localPath` on the pod filesystem. |
| `generic-secret` | Remote S3 path is synced into a Kubernetes `Opaque` Secret and mounted at `localPath`. |
| `tls-secret` | Remote S3 path (must contain `tls.key` + `tls.crt`) is synced into a Kubernetes `kubernetes.io/tls` Secret, usable by nginx-ingress, and mounted at `localPath`. |
| `ca-secret` | Each file in the remote S3 path is synced into an individual Kubernetes Secret and imported into the NiFi truststore. |

### Disabling individual paths

Each path entry supports an optional `enabled` field (default: `true`). Set it to `false` to skip that path entirely without removing it from the configuration:

```yaml
NiFiSync:
  syncPaths:
    - pathName: ingress-cert
      enabled: false   # skip this path in AWS deployments
      localPath: /opt/nifi/data/custom/tls/nifi-ingress-cert
      remotePath: system/nifi-ingress-cert
      pathType: tls-secret
```

When `enabled: false`, the path is excluded from:
- Kubernetes Secret and volume creation
- S3 sync (both the StatefulSet sidecar and the Deployment)
- Container volumeMounts (server and cert-manager sidecars)

### Automatic suppression of `tls-secret` paths when ingress is disabled

`tls-secret` paths exist to supply TLS credentials to an nginx-ingress controller. When `ingress.enabled: false` in `values.yaml`, there is no ingress to serve — so all `tls-secret` paths are automatically skipped across all templates without requiring a manual `enabled: false` on each path.

This means the following configuration requires no changes when toggling `ingress.enabled`:

```yaml
ingress:
  enabled: false   # ingress-cert path is automatically suppressed

NiFiSync:
  syncPaths:
    - pathName: ingress-cert
      enabled: true   # this per-path flag is still respected, but ingress.enabled takes precedence
      pathType: tls-secret
      ...
```

To override this behaviour and force a `tls-secret` path to be processed even when ingress is disabled, set `ingress.enabled: true` or use `pathType: generic-secret` instead.
