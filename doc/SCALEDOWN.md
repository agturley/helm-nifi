Scaling Down Safely
===================

Removing a node from a NiFi cluster is dangerous by default: if a node still has
FlowFiles queued when it's torn down, that data is gone unless it gets relocated
to another node first. This chart handles that relocation automatically, entirely
through `helm upgrade` - no extra scripts, kubectl commands, or manual steps
required.

## How draining works

Every node's `server` container has a `preStop` lifecycle hook that runs before
the container is stopped. When a node is actually being removed, it:

1. Disconnects the node from the cluster.
2. Requests an `offload`, which asks the cluster to relocate this node's queued
   FlowFiles onto other connected nodes.
3. Polls the node's own local queue count until it reaches zero (not a fixed
   timeout - it keeps waiting as long as the count is still going down, and only
   gives up if it stalls for `properties.drainQueueStallLimit` consecutive polls
   or hits the `properties.drainQueueTimeoutSeconds` ceiling).
4. Only once the local queue is confirmed empty does it call `delete-node` to
   remove the node from the cluster's registry.

### Budgeting the termination grace period

The kubelet applies `terminationGracePeriodSeconds` to `preStop` **and** the
container's own SIGTERM handling *together*, then SIGKILLs whatever is left. A
grace period smaller than the drain can need therefore doesn't shorten the
drain - it truncates it partway through, which is the one outcome this whole
mechanism exists to avoid, and it fails quietly (content stays safe on the PVC,
but nothing reports that it never moved).

So with `scaleDownGuard.enabled: true` the chart refuses to render unless:

```
terminationGracePeriodSeconds >= 2 * properties.drainStateWaitSeconds
                                  + properties.drainQueueTimeoutSeconds
                                  + properties.drainShutdownReserveSeconds
```

With the shipped defaults that is `2*60 + 180 + 30` = **330**, against a default
`terminationGracePeriodSeconds` of `30`. Enabling the guard without raising the
grace period is a template error, not a silent misconfiguration - the message
names both numbers and the minimum required.

### Why `drainStateWaitSeconds` defaults to 60

Because a scale-down always removes the **highest ordinal**, and that node is
often the elected cluster coordinator. Disconnecting the coordinator leaves the
cluster leaderless until a new one is elected, and during that window every
surviving peer rejects `get-nodes` - which is precisely the call the hook is
polling with while it waits for `DISCONNECTED`.

This was measured, not guessed. On a live two-node cluster, disconnecting the
coordinator produced a ~15s leaderless gap:

```
18:59:36  node 1 -> DISCONNECTED
18:59:50  node 0: "This node has been elected Active Cluster Coordinator"
18:59:55  first successful get-nodes (poll attempt 9)
```

At the original 25s ceiling that succeeded with about 8 seconds to spare. Had the
election run slightly longer, the hook would have logged `timeout waiting for
DISCONNECTED; skipping offload`, exited 0, and left the node's queued content
stranded - the exact silent failure this mechanism exists to prevent. Raising the
ceiling costs nothing on the happy path, since the wait returns as soon as the
state is observed.

If the queue never drains (e.g. genuinely un-relocatable content), the hook exits
non-zero and deliberately skips `delete-node` - the node is left visible in the
cluster as a `DISCONNECTED`/`OFFLOADED` registry entry instead of being silently
cleaned up. Its data is safe on its PVC (see `persistentVolumeClaimRetentionPolicy:
{whenScaled: Retain}` in the StatefulSet) and becomes available again if that
ordinal is scaled back up.

### Debugging a drain

The `preStop` hook runs as a separate kubelet exec session, so its own output is
**not** captured by `kubectl logs` - it's silently discarded on success, and
reduced to a bare `PreStopHook failed` event on failure. Every node instead logs
a timestamped line for each step to `/opt/nifi/data/prestop-timeline.log`, on the
node's own persistent volume, so the full timeline survives even after the pod is
gone (read it live with `kubectl exec <pod> -c server -- cat
/opt/nifi/data/prestop-timeline.log` while it's still terminating, or later by
remounting the retained PVC).

## Offload only runs for a real scale-down

The `preStop` hook is only rendered into the pod template when
`scaleDownGuard.enabled: true`. With the guard off (the default) there is no hook
at all, so nothing about pod termination changes and enabling the chart's other
features costs an existing deployment no pod-template churn.

With the guard on, the hook opens with a live check: it compares this pod's own
ordinal against the StatefulSet's *current* `spec.replicas`, fetched from the
Kubernetes API rather than read from the pod's own spec - a terminating pod's
spec is frozen at creation time and can never reflect a later scale-down. If the
ordinal is still within the desired replica count, this is just a restart and the
pod will be recreated, so the hook skips straight to `nifi.sh stop` with no
offload. Offload runs only when the ordinal is actually being permanently
removed.

The check fails **closed**, toward skipping. If the API can't be read at all -
transient unavailability, or the StatefulSet itself is being deleted by a
`helm uninstall` - the hook cannot tell a scale-down from a restart, and skips.
That direction matters: treating "unknown" as a scale-down would mean that during
a `helm uninstall`, where every pod terminates at once and no healthy peer exists
to receive anything, all nodes would simultaneously attempt a full drain against
each other and each burn its entire grace period before dying anyway.

That live check needs read access to the StatefulSet. Rather than grant that to
the pods' own `sts.serviceAccount` (used unconditionally by every deployment),
`scaleDownGuard.enabled: true` creates a separate, narrowly-scoped identity
(`templates/scaledown-guard-sts-reader.yaml`): its own `ServiceAccount` with a
long-lived token `Secret`, and a `Role`/`RoleBinding` granting only `get` on this
one named StatefulSet - the same pattern the chart already uses for
`cert-manager`'s secret-reading sidecar. The main pod identity never carries any
Kubernetes API permissions.

That separation is a deliberate trade-off, not a free win, and it is worth
stating the cost plainly. A manually-created `kubernetes.io/service-account-token`
Secret is a **non-expiring** credential that lives in etcd and is mounted into
every NiFi pod, so anyone who can `exec` into a node can read a token that never
rotates. The alternative - granting the pods' own ServiceAccount that same
`get`-on-one-StatefulSet and using the projected token the kubelet already
mounts - would give a short-lived, auto-rotating, pod-bound credential instead.
The current design is preferred here because it keeps the blast radius of the
*main* identity at exactly zero permissions across every deployment of this
chart, including ones that never enable this feature; but if your threat model
weights credential lifetime more heavily than identity separation, switching to
the pod SA plus a projected token is the better choice.

## What gets created, and when

Nothing described on this page is created by default. Every resource is gated
behind `scaleDownGuard.enabled`, which is `false` out of the box - this matters
in environments with restricted permissions (e.g. a locked-down AWS deployment),
where you may want none of this touching the cluster at all.

| `values.yaml`                          | Default | Creates |
|-----------------------------------------|---------|---------|
| `scaleDownGuard.enabled`                 | `false` | The `preStop` drain hook itself, plus a cluster-scoped `ValidatingAdmissionPolicy` + Binding that blocks scaling down by more than `maxStepDown` replicas in a single `helm upgrade`/`kubectl scale`/HPA action, plus the `sts-reader` identity above. |
| `scaleDownGuard.walkdown.enabled`        | `false` | (Requires `scaleDownGuard.enabled: true`.) A `pre-upgrade` Helm hook Job (with its own dedicated, hook-scoped `ServiceAccount`/`Role`/`RoleBinding`, cleaned up automatically after it runs) that walks a large `replicaCount` decrease down to `maxStepDown`-sized steps automatically, so a single `helm upgrade` with a much lower `replicaCount` still succeeds against the guard above in one command. |

`scaleDownGuard.enabled: true` with `walkdown.enabled: false` (the middle ground)
is a reasonable default for most homelab/dev use: the offload-vs-restart
distinction and the one-step-at-a-time guard are both active, but decrementing
`replicaCount` by more than `maxStepDown` requires you to do it incrementally
yourself rather than the chart doing it for you in one `helm upgrade`.

### The walkdown Job's image and deadline

The Job needs nothing but `kubectl` on the `PATH` and a POSIX shell; its script
deliberately avoids bashisms so a minimal busybox/ash base works. It defaults to a
**pinned** `alpine/kubectl` tag rather than `bitnami/kubectl:latest`, which since
the Bitnami catalog change no longer publishes any versioned tag you could pin
to. An unpinned, continuously-rebuilt image is a poor thing to gate production
upgrades on: a bad upstream push becomes a failed `helm upgrade`, potentially
with the StatefulSet stranded at an intermediate replica count.

`walkdown.activeDeadlineSeconds` is derived rather than fixed. The Job can't know
the cluster's live replica count at render time, but it can never exceed the
identity-pool ceiling, so the chart bounds the step count at
`ceil((maxReplicaCount - replicaCount) / maxStepDown)` and budgets
`stepTimeoutSeconds + settlePauseSeconds` per step, plus a minute. Set the value
explicitly only to override that - a deadline too small for the walk it's asked
to perform kills the Job mid-descent, which is strictly worse than not running it.

### The admission policy is cluster-scoped

`ValidatingAdmissionPolicy` and its Binding are cluster-scoped objects, so both
are named `<namespace>-<fullname>-scaledown-guard`. The namespace prefix is not
decoration: without it, two releases of this chart resolving to the same fullname
in different namespaces collide on a single cluster-wide name, and the second
install either fails outright or adopts the first one's policy - whose
`matchConditions` point at the wrong namespace, silently guarding nothing.

A policy's `matchConstraints` cannot themselves be namespaced, so this one
necessarily selects **every** StatefulSet UPDATE in the cluster and then filters
in CEL - and with `failurePolicy: Fail`, an evaluation error would reject those
requests cluster-wide. The Binding therefore carries a `namespaceSelector` on
`kubernetes.io/metadata.name` (a label the API server sets on every namespace
automatically), which narrows the match at the API server before any CEL runs.
Note that `namespaceSelector` is used rather than `objectSelector` for the same
reason the `matchConditions` compare names instead of labels: `kubectl scale` and
the HPA go through the `statefulsets/scale` subresource, whose `Scale` object
carries no labels at all, so an `objectSelector` would silently never match those
requests. `namespaceSelector` matches labels on the *Namespace*, so it works for
both paths.

### Why the guard's RBAC and the walkdown Job's RBAC aren't merged

The walkdown Job's own Role already grants `get` (plus `patch`, and read access to
`events`) on the same StatefulSet the `sts-reader` identity reads. These are
deliberately kept as two separate identities rather than merged into one,
because they have very different exposure: the walkdown Job's token is
short-lived and scoped to a one-shot pre-upgrade Job, while `sts-reader`'s token
is long-lived and mounted into every running node continuously. Widening that
long-lived, broadly-distributed credential to also carry `patch` and `events`
access - just to save creating one extra `Role` - would be a real
least-privilege regression for no real benefit.

## Concurrent scale-down

The chart supports `sts.podManagementPolicy: Parallel`, which lets multiple nodes
scale down (or up) at once instead of one at a time. Earlier versions of this
drain mechanism had a real bug here - two nodes disconnecting/offloading
concurrently could race and leave one node's content stranded - traced back to
the headless Service not setting `publishNotReadyAddresses: true`. Once a node
disconnects from the cluster its readiness probe flips, and without that setting
Kubernetes drops it from the headless Service's endpoints, breaking peer DNS
resolution to it mid-offload. That's now fixed, and has been validated with a
live test scaling three nodes down to one in a single step (`maxStepDown: 2`,
`walkdown.enabled: false`): both removed nodes drained fully in parallel with no
data loss.

`scaleDownGuard.maxStepDown` still defaults to `1` as a conservative default
regardless, since it caps the blast radius of *any* unexpected scale-down
behavior, not just the specific race above.

## Related: noticing when a node is *not* in the cluster

Everything above assumes you can tell whether a node is actually clustered. By
default you cannot: readiness is a TCP check on the HTTPS port, so a node that
has fallen out of the cluster still reports `Ready` while doing no clustered work
— which also lets a rolling update proceed to the next pod on the strength of a
node having merely restarted.

`sts.readinessProbe.requireClusterConnection: true` changes readiness to mean
"this node has joined the cluster", which surfaces that state as `NotReady` and
makes a rolling update wait for each node to genuinely rejoin. It composes with
the drain: during `preStop` the node deliberately disconnects and correctly
leaves the Service endpoints, while the headless Service's
`publishNotReadyAddresses: true` keeps peer DNS resolvable so the offload can
still complete.

See [Cluster-aware readiness](INSTALLATION.md#cluster-aware-readiness-stsreadinessproberequireclusterconnection)
for the full configuration.
