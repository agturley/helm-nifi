Migration Guide
================

## 2.9.0 → 2.10.0+

---

### Breaking Changes

These changes **require updates to your override `values.yaml`** before upgrading.

---

#### 1. `VaultNiFiSecrets.traVaultSecrets` renamed to `VaultNiFiSecrets.vaultSidecar`; vault logic brought in-chart

Two changes happened together:

**a) Config block renamed.** The vault sidecar configuration block has been renamed from `traVaultSecrets` to `vaultSidecar`.

**Before (2.9.0):**
```yaml
VaultNiFiSecrets:
  secretProvider: vaultSecretOperator  # or traVaultSecrets
  traVaultSecrets:
    logging: false
    restproxy_url: "https://your-kafka-restproxy"
    topic: 'your-vault-log-topic'
    syncMode: interval
    syncInterval: 10
```

**After (2.10.0):**
```yaml
VaultNiFiSecrets:
  secretProvider: vaultSecretOperator  # or vaultSidecar
  vaultSidecar:
    image: "your-python3-image:tag"  # required when secretProvider=vaultSidecar
    installPackages: true  # installs hvac+pyyaml at startup
    logging: false
    restproxy_url: "https://your-kafka-restproxy"
    topic: 'vault-logs'
    syncMode: interval
    syncInterval: 10
```

> **Note:** `secretProvider: traVaultSecrets` is no longer a valid value. Use `vaultSidecar` instead.

**b) Vault sidecar logic is now chart-owned.** The external vault sidecar binary has been replaced by a Python script (`vault-sync.py`) embedded directly in the chart — the same approach used by the AWS Secrets Manager sidecar. The chart now controls the full sync logic, including the new `flattenTo` capability.

`vaultSidecarImage` has been removed. The image is now configured as `vaultSidecar.image` and remains required. If you previously set `vaultSidecarImage` to a custom binary, move it to `vaultSidecar.image` and ensure it is a Python 3 compatible image. Set `installPackages: true` to install `hvac` at startup, or use a pre-built image that already includes it.

HTTP-based readiness/liveness probes (`/ready`, `/healthz`) have been replaced with `exec` probes that check `/tmp/vault-sync-healthy`. No changes are needed in your values, but be aware if you have custom probe overrides.

---

#### 2. `VaultNiFiSecrets.defaultSecretAddress` no longer has a default

The hardcoded default value has been removed. If you use the vault sidecar and rely on `defaultSecretAddress`, you must set it explicitly.

```yaml
VaultNiFiSecrets:
  defaultSecretAddress: "https://your-vault-address"
```

---

#### 3. `ca` section removed — nifi-toolkit CA server discontinued

The built-in nifi-toolkit CA server (`ca.enabled`) has been removed. Use `certManager` instead.

**Before (2.9.0):**
```yaml
ca:
  enabled: true
  server: ""
  service:
    port: 9090
  token: sixteenCharacters
  admin:
    cn: admin
```

**After (2.10.0):** Remove the `ca` block entirely and configure cert-manager:
```yaml
certManager:
  enabled: true
  manageCerts: true
  keystorePasswd: "changeme"
  truststorePasswd: "changeme"
```

See [INSTALLATION.md — cert-manager TLS](INSTALLATION.md#cert-manager-tls-certmanager) for full options.

---

#### 4. `openldap` subchart removed

The bundled `openldap` subchart has been removed from the chart dependencies. If you relied on it for testing, deploy OpenLDAP separately and point `auth.ldap.host` at it.

Remove any `openldap:` block from your override values.

---

#### 5. `certManager.additionalDnsNames` default changed

The default changed from `[localhost]` to `[]`. If you used `kubectl port-forward` to access the cluster and relied on `localhost` being in the cert SAN, add it back explicitly:

```yaml
certManager:
  additionalDnsNames:
    - localhost
```

---

#### 6. `labels.prefix` default changed

The default `labels.prefix` changed from a non-empty string to `""`. If you were relying on the old default, set it explicitly to preserve existing behaviour:

```yaml
labels:
  prefix: "your-org.com"
```

> **Important:** Kubernetes StatefulSet selectors are immutable. If you change label values, you must delete and re-create the StatefulSet (with `helm delete` + `helm install`), not `helm upgrade`.

---

#### 7. s3sync sidecar now uses `boto3` instead of `mc`

The s3sync sidecar image (`NiFiSync.s3Sync.sidecar.image`) must now bundle **Python 3 + boto3**. The MinIO `mc` client is no longer used. The default image (`docker.io/agturley/nifi-utility:v1`) already includes boto3.

If you were using a custom sidecar image, update it to include `boto3`. `pyyaml` is no longer required.

New s3Sync fields available to configure the boto3 client:

```yaml
NiFiSync:
  s3Sync:
    region: us-east-1     # AWS region for the boto3 S3 client
    insecure: false       # skip TLS verification (MinIO/test only)
    useIRSA: false        # use EKS IRSA / EC2 instance profile instead of static keys
```

---

#### 8. `NiFiSync.s3Sync.enable` renamed to `enabled` (bug fix)

The key was misspelled in `values.yaml`. Most templates already used `enabled` (the correct spelling), so in practice the default value was never applied. If you had `NiFiSync.s3Sync.enable: true` in your override values, rename it:

```yaml
NiFiSync:
  s3Sync:
    enabled: true   # was: enable
```

---

#### 9. `Logging` renamed to `clusterLogging`

The uppercase `Logging` block (for the Banzai Cloud Logging Operator) has been renamed to `clusterLogging` to avoid confusion with the lowercase `logging` block (which controls logback `extraLoggers`).

```yaml
# Before
Logging:
  enabled: true
  clusterOutput: my-output
  kubernetesDnsServer: rke2-coredns...

# After
clusterLogging:
  enabled: true
  clusterOutput: my-output
  kubernetesDnsServer: rke2-coredns...
```

---

#### 10. `hashicorp` block removed

The top-level `hashicorp:` block was dead code — no template referenced `.Values.hashicorp`. Vault integration is handled by `VaultNiFiSecrets`. Remove any `hashicorp:` block from your override values.

---

#### 11. `env` secrets modes removed (file-based secrets only)

In 2.10, the chart no longer supports environment-variable secret delivery for chart-managed secrets.

- `properties.secretsMode: env` was removed.
- `VaultNiFiSecrets.defaultSecretMode: env` was removed.
- `VaultNiFiSecrets.secrets[].secretMode: env` was removed.
- `properties.UseK8sSecrets` compatibility mode was removed.

Use file-based modes instead:

```yaml
properties:
  secretsMode: file-dir    # or file-single

VaultNiFiSecrets:
  defaultKvVersion: 2
  defaultSecretMode: directory
  secrets:
    - name: nifi-secrets
      secretMode: file      # or directory or aws-credential
      # kvVersion: 1         # optional override for KV v1 mounts
```

---

#### 12. `flowRestore.interval` renamed to `flowRestore.intervalMinutes`

Flow restore polling now uses an explicit minutes key.

```yaml
NiFiSync:
  s3Sync:
    flowRestore:
      enabled: true
      intervalMinutes: 1   # was: interval: 30 (seconds)
```

---

### New Features (no migration required)

These are additive. Existing installs continue to work without setting them.

| Feature | Key | Default |
|---|---|---|
| Dynamic logback loggers | `logging.extraLoggers` | `[]` |
| Auto-generate single-user password | `auth.singleUser.generateSecret` | `false` |
| Optional OU on cert subjects | `certManager.nodeOU` | `"NIFI"` |
| Skip cert CRD creation (supply certs manually) | `certManager.manageCerts` | `true` |
| Use existing ClusterIssuer | `certManager.issuerRef.name` | `""` |
| Add CA secrets to NiFi truststore | `certManager.caSecrets` | `[]` |
| Kubernetes-native cluster state (NiFi 2.x, no ZK) | `kubernetesClusterState.enabled` | `false` |
| Override ZooKeeper connect string | `zookeeper.connectString` | *(not set)* |
| Skip ZooKeeper connectivity init container | `zookeeperInit.enabled` | `false` |
| Add extra syncPaths without overwriting defaults | `NiFiSync.additionalSyncPaths` | `[]` |
| Disable K8s secret sync while keeping fs sync | `NiFiSync.s3Sync.secretSync.enabled` | `true` |
| Per-path enable/disable | `NiFiSync.syncPaths[].enabled` | `true` |
| Prune local files no longer in S3 | `NiFiSync.syncPaths[].deleteOrphans` | `"dryrun"` |
| Shared S3 prefix override per path | `NiFiSync.syncPaths[].remoteRoot` | *(not set)* |
| On-demand flow restore from S3 | `NiFiSync.s3Sync.flowRestore.enabled` | `false` |
| s3sync resource limits | `NiFiSync.s3Sync.resources` | *(see values.yaml)* |
| Debug: reset auth files on sidecar restart | `NiFiSync.UserPolicySync.resetAuthFiles` | `false` |
| Flatten JSON AWS secrets to individual files | `awsSecretsSync.secrets[].flattenTo` | *(not set)* |
| Flatten Vault secrets to a flat directory | `VaultNiFiSecrets.secrets[].flattenTo` | *(not set)* |
| Skip hvac install (pre-built vault image) | `VaultNiFiSecrets.vaultSidecar.installPackages` | `true` |
| Credential management modes | `properties.secretsMode` | `""` (none), supports `none`, `file-dir`, `file-single` |

See [INSTALLATION.md](INSTALLATION.md) for full documentation on each feature.

---

### Upgrade Steps

1. **Update your override `values.yaml`** to address all breaking changes above.
2. **Run a diff** to validate the rendered templates before applying:
   ```bash
   helm diff upgrade <release> . -f your-override-values.yaml
   ```
   *(Requires the [helm-diff](https://github.com/databus23/helm-diff) plugin.)*
3. **Upgrade**:
   ```bash
   helm upgrade <release> . -f your-override-values.yaml
   ```
4. If you changed `labels.prefix` (see item 6 above), perform a `helm delete` + `helm install` instead of `helm upgrade`.
