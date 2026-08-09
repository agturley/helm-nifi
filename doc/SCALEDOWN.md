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

By default (`scaleDownGuard.enabled: false`), the sequence above runs on **every**
pod removal - a genuine scale-down, a rolling update, or a plain `kubectl delete
pod`. That's the safe default, but it means routine restarts pay the cost of a
disconnect/offload/drain cycle they don't actually need.

Setting `scaleDownGuard.enabled: true` turns on a live check at the top of the
`preStop` hook: it compares this pod's own ordinal against the StatefulSet's
*current* `spec.replicas` (fetched from the Kubernetes API, not baked into the
pod's own spec, since a removed pod's spec is frozen at creation time and can
never reflect a later scale-down). If the ordinal is still within the desired
replica count, this is just a restart - the pod will be recreated - so the hook
skips straight to `nifi.sh stop` with no offload. Offload only runs when the
ordinal is actually being permanently removed.

That live check needs read access to the StatefulSet. Rather than grant that to
the pods' own `sts.serviceAccount` (used unconditionally by every deployment),
`scaleDownGuard.enabled: true` creates a separate, narrowly-scoped identity
(`templates/scaledown-guard-sts-reader.yaml`): its own `ServiceAccount` with a
long-lived token `Secret`, and a `Role`/`RoleBinding` granting only `get` on this
one named StatefulSet - the same pattern the chart already uses for
`cert-manager`'s secret-reading sidecar. The main pod identity never carries any
Kubernetes API permissions.

## What gets created, and when

Nothing described on this page is created by default. Every resource is gated
behind `scaleDownGuard.enabled`, which is `false` out of the box - this matters
in environments with restricted permissions (e.g. a locked-down AWS deployment),
where you may want none of this touching the cluster at all.

| `values.yaml`                          | Default | Creates |
|-----------------------------------------|---------|---------|
| `scaleDownGuard.enabled`                 | `false` | A cluster-scoped `ValidatingAdmissionPolicy` + Binding that blocks scaling down by more than `maxStepDown` replicas in a single `helm upgrade`/`kubectl scale`/HPA action. Also creates the `sts-reader` identity above, enabling the offload-vs-restart check. |
| `scaleDownGuard.walkdown.enabled`        | `false` | (Requires `scaleDownGuard.enabled: true`.) A `pre-upgrade` Helm hook Job (with its own dedicated, hook-scoped `ServiceAccount`/`Role`/`RoleBinding`, cleaned up automatically after it runs) that walks a large `replicaCount` decrease down to `maxStepDown`-sized steps automatically, so a single `helm upgrade` with a much lower `replicaCount` still succeeds against the guard above in one command. |

`scaleDownGuard.enabled: true` with `walkdown.enabled: false` (the middle ground)
is a reasonable default for most homelab/dev use: the offload-vs-restart
distinction and the one-step-at-a-time guard are both active, but decrementing
`replicaCount` by more than `maxStepDown` requires you to do it incrementally
yourself rather than the chart doing it for you in one `helm upgrade`.

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
