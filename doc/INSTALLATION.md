Installation
=============


### Install from local clone

1. **Clone the repo**

```bash
git clone https://github.com/agturley/helm-nifi.git
cd helm-nifi
```

The chart has exactly one dependency — the optional ZooKeeper subchart — and a
copy is already vendored under `charts/`, so no repositories need to be added
for a normal install. Only refresh it if you actually intend to run ZooKeeper
and want a newer version than the vendored one:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm dep up
```

Most NiFi 2.x deployments skip ZooKeeper entirely and use Kubernetes Leases for
leader election instead — see
[Kubernetes-Native Cluster State](#kubernetes-native-cluster-state-kubernetesclusterstate--nifi-2x).

2. **Set a sensitiveKey and configure credential management**

NiFi (current chart: `images.nifi.tag: "2.11.0"`) requires a `sensitiveKey` (minimum 12 characters) to encrypt sensitive flow data. Set it in `values.yaml`:

````
properties:
  sensitiveKey: "changeMechangeMe"  # minimum 12 characters
````

The `secretsMode` property controls how the container reads runtime credentials at startup. See [Credential Management](#credential-management-propertiessecretsmode) for available modes (`none`, `file-dir`, `file-single`).

3. **Configure a user authentication**

This helm chart provides three types of authentication: Single User, LDAP and OIDC.

You can find how to configure these authentications on this [page](USERMANAGEMENT.md).

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

Each path also supports an optional `remoteRoot` field that overrides the per-cluster `instanceName` as the top-level S3 folder. Use this for shared prefixes read by multiple clusters:

| `remoteRoot` | Effective S3 path |
|---|---|
| *(not set, default)* | `s3://<bucket>/<prefix>/<instanceName>/<remotePath>` |
| `remoteRoot: enrichment` | `s3://<bucket>/<prefix>/enrichment/<remotePath>` |

Paths with `remoteRoot` are read-only from the sidecar's perspective — no placeholder is written and the path is never uploaded, only mirrored down.

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

### Disabling the Kubernetes secret-sync Deployment

`NiFiSync.syncPaths` are handled by two different components:

- **`fs` paths** are mirrored by the **s3sync sidecar** that runs inside the NiFi StatefulSet (this sidecar also performs flow backups).
- **Secret-type paths** (`generic-secret`, `tls-secret`, `ca-secret`) are handled by a separate **`<release>-config-sync` Deployment**, which pulls those paths from S3 and writes them as Kubernetes Secrets — together with the RBAC it needs to do so (a ServiceAccount, Role, RoleBinding, and tokens).

If you only use `fs` paths (or no sync paths at all), the config-sync Deployment and its RBAC are unnecessary. Rendering of the Deployment — and all of its RBAC, the `create-secrets-vault.sh` script, and the synced-secret volume mounts — happens only when **all** of the following are true:

1. `NiFiSync.s3Sync.enabled: true`
2. `NiFiSync.s3Sync.secretSync.enabled: true` (the default)
3. at least one **enabled** `syncPath` has a `pathType` other than `fs`

```yaml
NiFiSync:
  s3Sync:
    enabled: true
    secretSync:
      enabled: false   # keep fs sync + flow backup, but never sync K8s secrets
```

Behaviour:

- **Auto-skip:** if there are no enabled non-`fs` paths, the Deployment, its RBAC, the `create-secrets-vault.sh` script, and the per-path secret volumes are simply not created — no orphaned ServiceAccounts/Roles/tokens are left behind. No toggle change is required.
- **Explicit off-switch:** set `secretSync.enabled: false` to disable secret syncing even when secret-type paths are still listed in `syncPaths`. The fs-sync sidecar and flow backup on the StatefulSet keep running. The synced-secret volume mounts are dropped from the NiFi and cert-manager containers at the same time, so pods still start cleanly (they just won't have those secrets mounted).

### Pruning local files removed from S3 (`deleteOrphans`)

For `fs` paths, an optional `deleteOrphans` field controls whether local files that no longer exist in S3 are removed (similar to `mc mirror --remove`):

| Value | Behaviour |
|---|---|
| `"dryrun"` *(default)* | Logs which local files **would** be removed, without deleting anything. |
| `"delete"` | Removes local files that are not present in S3. |
| `"off"` | Never prunes. |

Booleans are also accepted (`true` = `delete`, `false` = `off`). For safety, pruning is **always skipped** when S3 is unreachable or the remote prefix returns no objects, so the local folder is never wiped by an outage or a misconfigured bucket/prefix.

```yaml
NiFiSync:
  syncPaths:
    - pathName: custom-drivers
      pathType: fs
      localPath: /opt/nifi/data/custom/drivers
      remotePath: custom/drivers
      deleteOrphans: "off"      # in-use jars; don't prune
    - pathName: custom-config
      pathType: fs
      localPath: /opt/nifi/data/custom/config
      remotePath: custom/config
      deleteOrphans: "delete"   # mirror this path exactly
```

### `additionalSyncPaths` — Extending paths without overwriting chart defaults

`NiFiSync.syncPaths` contains the chart's default set of paths. To add extra paths in an override `values.yaml` without clobbering those defaults, use `NiFiSync.additionalSyncPaths`. All the same fields are supported (`pathName`, `localPath`, `remotePath`, `pathType`, `remoteRoot`, `deleteOrphans`, `enabled`):

```yaml
NiFiSync:
  additionalSyncPaths:
    - pathName: enrichment-data
      localPath: /opt/nifi/data/enrichment
      remotePath: data
      pathType: fs
      remoteRoot: enrichment     # shared bucket prefix across clusters
      deleteOrphans: "dryrun"
```

---

## Credential Management (`properties.secretsMode`)

`properties.secretsMode` controls how the NiFi container reads runtime credentials (TLS passwords, LDAP bind password, `sensitiveKey`, S3 keys, etc.) at startup:

| Mode | Behaviour |
|---|---|
| `none` | Credentials are rendered directly from `values.yaml`. **Non-production / demo only.** |
| `file-dir` | Each credential is a separate file inside `secretsFilePath/`, named after its key (e.g. `NIFI_TLS_KEYSTORE_PASSWORD`). Compatible with K8s Secrets projected as individual files, VSO, and the `awsSecretsSync` sidecar. (`UseK8sSecrets` was removed in 2.10.) |
| `file-single` | All credentials live in one `KEY=VALUE` (`.env`) file at `secretsFilePath/secretsFile`. The file is sourced with `set -a; . FILE; set +a` at startup. |

`env` mode was removed in 2.10. The chart now uses file-based secrets only.

```yaml
properties:
  secretsMode: "file-dir"
  secretsFilePath: /opt/nifi/secrets   # base directory for file-dir / file-single
  secretsName: ""                      # optional K8s Secret name to project into secretsFilePath
  secretsFile: "credentials.env"       # filename for file-single mode
```

### Precedence

`secretsMode` selects a *source*, it does not make that source exclusive. At
startup each credential is resolved in this order, highest first:

1. **the `secretsMode` source** — the Vault/AWS file for `file-dir`, or the
   sourced env file for `file-single`
2. **the process environment** — normally an `envFrom` secretRef on the pod
3. **`values.yaml`** — the literal, used only when nothing above supplied a value

So `envFrom` and `secretsMode` compose rather than conflict, and a credential
present in a Secret does not also have to be restated in `values.yaml`. A file
that is missing or empty falls through to the next source instead of blanking
the value.

These are the keys resolved this way:

| Key | `values.yaml` fallback |
|---|---|
| `NIFI_TLS_KEYSTORE_PASSWORD` | `certManager.keystorePasswd` |
| `NIFI_TLS_TRUSTSTORE_PASSWORD` | `certManager.truststorePasswd` |
| `NIFI_SENSITIVE_PROPS_KEY` | `properties.sensitiveKey` |
| `LDAP_MANAGER_DN` | `auth.ldap.admin` |
| `LDAP_MANAGER_PASSWORD` | `auth.ldap.pass` |
| `INITIAL_ADMIN_IDENTITY` | `auth.admin`, or `auth.oidc.admin` when OIDC is enabled |

Supplying them from a Secret in `none` mode needs nothing beyond `envFrom`:

```yaml
envFrom:
  - secretRef:
      name: nifi-secrets
```

See [Initial admin identity](USERMANAGEMENT.md#initial-admin-identity) for how
this interacts with seeding the NiFi administrator.

---

## Cluster-aware readiness (`sts.readinessProbe.requireClusterConnection`)

By default readiness is a TCP check on the HTTPS port. That answers "is the
process listening", which is not the same question as "is this node doing any
clustered work" — a node can drop out of the NiFi cluster and keep accepting
connections on that port indefinitely. It stays in the Service's endpoints
serving requests it cannot fulfil, and a rolling update moves on to the next pod
because this one "came back".

```yaml
sts:
  readinessProbe:
    requireClusterConnection: true   # default: false
    periodSeconds: 20
    timeoutSeconds: 10
    failureThreshold: 3
```

When enabled, readiness instead calls `GET /nifi-api/controller/cluster` on the
node itself and requires the node's **own** entry to report `CONNECTED`. Both
failure modes are covered: a node that has left the cluster rejects that endpoint
outright, and a node still listed as `DISCONNECTED`/`OFFLOADING` fails the status
check. The probe prints the full cluster roster when it fails, so
`kubectl describe pod` shows why.

Only applies when `properties.isNode: true` — a standalone node has no cluster to
join and keeps the TCP check.

**Liveness deliberately stays a TCP check.** Losing cluster membership is a
reason to stop sending a node traffic, not a reason to restart it: a node that
has dropped out is usually mid-rejoin, and a cluster-aware liveness probe would
turn a cluster-wide disruption into a simultaneous crash loop on every node.

Two consequences worth planning for:

- **Rolling updates get slower, deliberately.** Each pod must genuinely rejoin
  before the next is touched, which is the behaviour that prevents a rollout from
  silently leaving a node stranded outside the cluster.
- **It depends on authorization.** The check authenticates with the node's own
  certificate, which must be allowed to call `/nifi-api/controller/cluster`. That
  holds for the `authorizers.xml` this chart generates; a deployment with
  hand-managed authorizations should verify it before enabling, or every node
  will sit `NotReady`.

The probe needs a client certificate and NiFi keeps the node identity in a JKS
that `curl` cannot read, so it extracts a PEM copy into the container's own
`/tmp` on first run and reuses it, regenerating whenever the keystore is newer.
cert-manager renewals are therefore picked up without a restart.

---

## JVM Tuning (`jvm`)

```yaml
jvm:
  heapSize: "8g"
  gcCollector: "g1gc"    # Options: zgc, g1gc

  gcLogging:
    enabled: true
    path: "/opt/nifi/nifi-current/logs/gc.log"
    fileCount: 5
    fileSize: "20m"
```

Set `gcCollector: "zgc"` for low-latency workloads on Java 21+ (supports `generational: true`). Most GC tuning fields under `jvm.zgc` and `jvm.g1gc` can be left unset; the JVM self-tunes by default.

---

## cert-manager TLS (`certManager`)

When `certManager.enabled: true`, the chart creates a self-signed CA chain and per-node TLS certificates via cert-manager:

```yaml
certManager:
  enabled: false
  manageCerts: true             # set false to supply TLS secrets manually
  keystorePasswd: "keystorePasswd"      # placeholder default — override this
  truststorePasswd: "truststorePasswd"  # placeholder default — override this
  useMergedCACerts: true        # merge JVM cacerts + chart CAs into one truststore
  caDuration: 87660h            # CA lifetime (10 years)
  certDuration: 2160h           # node cert lifetime (90 days)
  additionalDnsNames: []
  caSecrets: []                 # K8s Secret names whose .crt/.pem files are added to the truststore
```

To use an existing `ClusterIssuer` instead of the chart-managed self-signed CA, set `issuerRef.name`:

```yaml
certManager:
  enabled: true
  manageCerts: true
  issuerRef:
    name: my-cluster-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

---

## Kubernetes-Native Cluster State (`kubernetesClusterState`) — NiFi 2.x+

NiFi 2.x can replace ZooKeeper with Kubernetes Leases and ConfigMaps for leader election and cluster state. When enabled, set `zookeeper.enabled: false` and ensure the NiFi ServiceAccount exists (either set `sts.serviceAccount.create: true` or create one manually).

```yaml
kubernetesClusterState:
  enabled: false
  leasePrefix: ""       # optional prefix for Lease names when multiple clusters share a namespace

zookeeper:
  enabled: false        # disable the built-in ZooKeeper subchart
```

---

## AWS Secrets Manager (`awsSecretsSync`)

A Python sidecar that fetches secrets from AWS Secrets Manager and writes them as files under `outputPath`, shared with the NiFi container. Authenticate via IRSA (annotate the pod's ServiceAccount with an IAM role ARN) or a static `credentialsSecret`:

```yaml
awsSecretsSync:
  enabled: false
  region: us-east-1
  outputPath: /opt/nifi/aws-secrets
  syncMode: interval    # interval = keep refreshing | once = fetch at startup only
  syncInterval: 10      # minutes; only used when syncMode=interval
  installPackages: true # set false when using a pre-built image with boto3+pyyaml
  credentialsSecret: "" # optional K8s Secret with AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
  secrets: []
  # - name: my/secret/name
  #   outputFile: my-secret
  #   flattenTo: ""      # also copy each JSON key as a flat file into this directory
```

When using `secretsMode: file-dir`, point `flattenTo` at `properties.secretsFilePath` so the keys land where the container startup script expects them.

---

## HashiCorp Vault (`VaultNiFiSecrets`)

```yaml
VaultNiFiSecrets:
  secretProvider: vaultSidecar          # vaultSidecar (default) | vaultSecretOperator
  enabled: false
  defaultSecretAddress: ""              # Vault server URL
  defaultContainerPath: /opt/nifi/secrets
  defaultKvVersion: 2                   # default KV engine version: 1 | 2
  defaultSecretMode: directory          # directory | singlefile | aws-credential

  vaultSidecar:                         # only used when secretProvider: vaultSidecar
    image: ""
    installPackages: false              # false when the image already has the deps
    skipTlsVerify: false
    caSecretName: ""                    # defaults to the first top-level caSecrets entry
    syncMode: interval                  # interval | once
    syncInterval: 10                    # minutes

  secrets:                              # each entry may override the defaults above
    - name: nifi-secrets
      # mount: secret                   # Vault mount
      # path: nifi/database             # path within the mount
      # secretMode: directory           # directory | singlefile | aws-credential
      # outputFile: db-credentials
      # kvVersion: 1                    # aws-credential defaults to 1 when omitted
```

Scope is per secret, not global: `mount`, `path`, `secretMode`, `outputFile` and
`kvVersion` are set on individual `secrets[]` entries, and the top-level
`default*` keys only supply the fallback for entries that omit them.

`aws-credential` mode reads standard AWS key aliases from a Vault secret and writes
an AWS credentials file under `<containerPath>/.aws/<secret-name>/credentials`, plus
optional `AWS_REGION` / `AWS_CREDENTIAL_TTL` exports for downstream consumers.
When `secretMode: aws-credential` is used, `kvVersion` defaults to `1` unless you
explicitly set a different `kvVersion` for that secret.

Set `secretProvider: vaultSidecar` and provide `vaultSidecar.image` when using a Vault Agent sidecar instead of the Vault Secrets Operator (VSO).

---

## NiFiSync — Flow Backup and Restore

The s3sync sidecar can periodically back up `flow.xml.gz` to S3 and (optionally) restore a previous version on startup:

```yaml
NiFiSync:
  s3Sync:
    enabled: true
    flowBackup:
      enabled: true
      interval: 1d
      retention:
        enabled: true
        dryRun: false
        flow:
          keepDays: 30       # delete flow backups older than X days
          maxVersions: 60    # keep only the newest N versioned flow files
        archive:
          enabled: true
          keepDays: 30

    flowRestore:
      enabled: false
      intervalMinutes: 1     # minutes between S3 restore-trigger polls
```

### Triggering a flow restore

When `flowRestore.enabled: true`, the s3sync sidecar polls S3 every `intervalMinutes` minutes for a restore trigger file at:

```
s3://<bucket>/<prefix>/<instanceName>/restore/<pod-name>/flow.json.gz
```

Use the following procedure to restore a specific flow version to a specific pod.

### Prerequisites

1. `NiFiSync.s3Sync.enabled: true`
2. `NiFiSync.s3Sync.flowRestore.enabled: true`
3. The NiFi ServiceAccount has permission to delete pods in the namespace
  (the chart creates Role/RoleBinding automatically when flowRestore is enabled).
4. You know:
  - the S3 bucket and embedded prefix configured for the deployment
  - the NiFi `instanceName`
  - the target pod ordinal/name (for example, `nifi-0`)

### Restore Procedure

1. **Identify the pod name** and the backup you want to restore from:
   ```bash
   kubectl get pods -l app=nifi
   # e.g. nifi-0
   ```

2. **Upload the desired `flow.json.gz`** to the trigger path (replace `<instanceName>` and `<pod>`):
   ```bash
   aws s3 cp flow.json.gz \
     s3://<bucket>/<prefix>/<instanceName>/restore/<pod>/flow.json.gz
   ```
   Alternatively, copy a versioned backup directly from S3:
   ```bash
   aws s3 cp \
     s3://<bucket>/<prefix>/<instanceName>/backup/<pod>/flow-backup/20240101T120000-flow.json.gz \
     s3://<bucket>/<prefix>/<instanceName>/restore/<pod>/flow.json.gz
   ```

3. **Wait for the sidecar to pick it up** (within `intervalMinutes` minutes). The sidecar will:
   - Archive the current `flow.json.gz` to the versioned backup path (as a `pre-restore` checkpoint).
   - Replace `flow.json.gz` with the restore file.
   - Delete the S3 trigger key (so it fires only once).
   - Delete the pod via the Kubernetes API, triggering a restart with the restored flow.

4. **Verify completion**:
   - Pod restarts and returns to Ready.
   - Trigger object no longer exists at:
     `s3://<bucket>/<prefix>/<instanceName>/restore/<pod>/flow.json.gz`
   - NiFi UI/API shows the expected restored flow.

### Operational Notes

- Restore is per pod. For multi-replica clusters, restore one pod at a time unless you have a coordinated cluster-level restore plan.
- The restore trigger is one-shot: after successful processing, the trigger object is removed.
- Keep `flowBackup.enabled: true` to preserve version history and automatic pre-restore checkpoints.

### Troubleshooting

- Trigger file remains in S3:
  - Verify sidecar logs for S3 access/auth errors.
  - Verify the trigger path includes the correct `<instanceName>` and `<pod-name>`.
- Pod does not restart:
  - Verify Role/RoleBinding for pod delete is present and bound to the NiFi ServiceAccount.
- Unexpected flow after restart:
  - Confirm the uploaded object is the intended `flow.json.gz` and that upload did not fail/overwrite unexpectedly.

> **RBAC note:** pod deletion requires a `Role` and `RoleBinding` that the chart creates automatically when `flowRestore.enabled: true`. Ensure `sts.serviceAccount.create: true` or that the NiFi ServiceAccount already exists.

---

## NiFiSync — User and Policy Sync (`UserPolicySync`)

When enabled, a sidecar manages NiFi `users.xml` and `authorizations.xml` based on the values below. Internal NiFi users and groups are created and tracked; external LDAP groups can be mapped to roles without being mirrored into `users.xml`:

```yaml
NiFiSync:
  UserPolicySync:
    enabled: false
    resetAuthFiles: false    # never enable in production

    externalGroupRoles:      # LDAP groups → NiFi roles (not created in users.xml)
    #  myLdapAdmins: admin
    #  myLdapRO: ro

    managedGroupRoles:       # internal NiFi groups → roles
    #  nifi-admins: admin
    #  nifi-rw: rw
    #  nifi-ro: ro

    managedUsers:            # internal NiFi users to create
    #  - alice
    #  - bob

    managedUserGroups:       # user → group membership
    #  alice:
    #    - nifi-admins
    #  bob:
    #    - nifi-ro
```
