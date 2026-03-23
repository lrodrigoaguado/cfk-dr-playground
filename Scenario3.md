# Scenario 3: Bidirectional Cluster Linking -- Failover and Failback with `truncate-and-restore`

## Overview

This scenario demonstrates the **recommended disaster recovery procedure** from the [Confluent DR White Paper]([20241120-White%20Paper-Disaster_Recovery_in_the_Cloud.pdf](https://www.confluent.io/resources/white-paper/best-practices-disaster-recovery/)) using a **bidirectional cluster link** managed via the `confluent` CLI and Kafka CLI tools. It showcases three key operations that simplify the entire failover/failback lifecycle:

| Operation | When to Use | Effect |
|---------|-------------|--------|
| **Failover** | Primary is unreachable (emergency) | Promotes mirror topics on Secondary to writable topics. Data flow stops. |
| **Truncate and Restore** | Primary recovers after failover | Truncates divergent records on Primary and converts its topics back to mirror topics, syncing from Secondary. |
| **Reverse and Start Mirror** | Ready to restore original topology | Reverses the data flow: Primary becomes source again, Secondary becomes mirror again. |

The `truncate-and-restore` operation is the centerpiece of this scenario. Without it, failing back requires manually deleting topics on the recovered cluster and re-creating them as mirrors (as in [Scenario 2](Scenario2.md)). With `truncate-and-restore`, the recovered cluster's topics are automatically truncated to match the failover point and converted to mirror topics in a single operation.

```
Steady State:    Primary (source) ════════► Secondary (mirror)
                      bidirectional link

Failover:        Primary (DOWN)              Secondary (active)
                                             topics promoted via failover

Truncate:        Primary (mirror) ◄═════════ Secondary (source)
                      topics restored via truncate-and-restore

Reverse:         Primary (source) ════════► Secondary (mirror)
                      roles swapped via reverse-and-start-mirror
```

> **Why bidirectional?** The `truncate-and-restore` and `reverse-and-start-mirror` operations are **only available with bidirectional cluster links**. A bidirectional link enables both directions of data flow on a single link, making failover and failback significantly simpler than managing two separate unidirectional links.

**Trade-offs**:

- Cluster links are **not managed by CfK** -- they are invisible to `kubectl get clusterlink`. CfK does not currently support [bidirectional cluster links](https://docs.confluent.io/operator/current/co-cluster-linking.html).
- Link management uses the `confluent` CLI (`confluent kafka link`); mirror topic operations use the `kafka-mirrors` Kafka CLI tool (since `confluent kafka mirror` commands do not support on-prem clusters).
- Risk of **state drift** between operator-managed and CLI-managed resources.

---

## Prerequisites

- You have completed the [DR Demo Setup](README.md) through **Step 1** (Deploy Topic, Schema, and Datagen Connector).
- The Confluent Platform is running on both clusters (all pods are `READY`).
- The Datagen connector is producing data on the Primary cluster.
- **`confluent` CLI installed** ([install guide](https://docs.confluent.io/confluent-cli/current/install.html))
- **Confluent Platform Kafka CLI tools installed locally** (provides `kafka-mirrors` -- included in the [Confluent Platform](https://docs.confluent.io/platform/current/installation/installing_cp/overview.html) `bin/` directory)
- **`/etc/hosts` entries configured** as described in the [README Setup Instructions](README.md#8-wait-for-all-pods) (`primary-control-plane` and `secondary-control-plane` -> `127.0.0.1`)
- The [TLS environment variables](README.md#access-via-confluent-cli) are set in your shell.

> **Note**: Do **not** complete DR Demo Setup Steps 2 and 3. This scenario creates its own bidirectional cluster link and handles the remaining setup steps internally.

---

## Shell Variables

If you haven't already, set all required environment variables:

```bash
source scripts/set-env.sh
```

This sets:

- TLS certificate paths for `confluent` CLI
- `PRIMARY_CLUSTER_ID` and `SECONDARY_CLUSTER_ID`
- `KAFKA_LOG4J_OPTS` to suppress Kafka CLI warnings

> **Note**: The `kafka-mirrors` CLI logs transient WARN messages (e.g., "cannot establish connection to node") while the Kafka client pre-connects to all brokers during metadata fetch. These are harmless — caused by mTLS handshake delays — but clutter the output. The `KAFKA_LOG4J_OPTS` setting above suppresses them by raising the log level to ERROR.

---

## Phase 1: Steady State Setup

### Step 1.1: Create the Bidirectional Cluster Link

A bidirectional cluster link requires creating the link on **both clusters** with `link.mode=BIDIRECTIONAL`. Both sides must use the same link name.

The link configuration files in [etc/scenario3/](etc/scenario3/) specify how each broker connects to the remote cluster using mTLS authentication.

**Create the link on the Secondary cluster** (connecting to Primary as remote):

```bash
confluent login --url https://localhost:30180 --certificate-only

confluent kafka link create bidirectional-link \
  --remote-cluster "$PRIMARY_CLUSTER_ID" \
  --url https://localhost:30180/kafka \
  --config etc/scenario3/link-on-secondary.config \
  --no-validate
```

**Create the link on the Primary cluster** (connecting to Secondary as remote):

```bash
confluent login --url https://localhost:30080 --certificate-only

confluent kafka link create bidirectional-link \
  --remote-cluster "$SECONDARY_CLUSTER_ID" \
  --url https://localhost:30080/kafka \
  --config etc/scenario3/link-on-primary.config \
  --no-validate
```

Verify the link exists on both sides:

```bash
confluent kafka link list --url https://localhost:30080/kafka

confluent kafka link list --url https://localhost:30180/kafka
```

You should see `bidirectional-link` listed on both clusters.

> **Note**: `kubectl get clusterlink` will return "No resources found" because bidirectional links are not managed by CfK.

### Step 1.2: Create Mirror Topics on Secondary

Create mirror topics on the Secondary cluster via the bidirectional link. Data flows from Primary (source) to Secondary (mirror):

```bash
kafka-mirrors --bootstrap-server secondary-control-plane:30192 \
  --command-config etc/scenario3/secondary-client.properties \
  --create --mirror-topic product-pageviews \
  --link bidirectional-link

kafka-mirrors --bootstrap-server secondary-control-plane:30192 \
  --command-config etc/scenario3/secondary-client.properties \
  --create --mirror-topic confluent.connect-offsets \
  --link bidirectional-link
```

### Step 1.3: Deploy Connect on Secondary

The `confluent.connect-offsets` mirror topic must exist before Connect starts. Now that it's created, deploy Connect:

```bash
kubectl -n confluent --context kind-secondary apply -f infra/secondary/connect.yaml
```

Wait for Connect to be ready:

```bash
kubectl -n confluent --context kind-secondary wait pod/connect-0 \
  --for=condition=Ready --timeout=600s
```

### Step 1.4: Deploy Schema Exporter

Start schema linking from Primary to Secondary (managed by CfK):

```bash
kubectl -n confluent --context kind-primary apply -f infra/primary/schema-exporter.yaml
```

### Step 1.5: Verify the Steady State

```bash
# List mirror topics on Secondary
kafka-mirrors --bootstrap-server secondary-control-plane:30192 \
  --command-config etc/scenario3/secondary-client.properties \
  --describe --links bidirectional-link
```

You should see:

- `bidirectional-link` on both clusters.
- Mirror topics `product-pageviews` and `confluent.connect-offsets` on Secondary, both in `ACTIVE` state.

Also verify in Control Center on the Secondary cluster that data is flowing into `product-pageviews`.

---

## Phase 2: Failover

This phase simulates an emergency where the Primary cluster becomes unreachable. We use `kafka-mirrors --failover` to promote the mirror topics on the Secondary.

### Step 2.1: Simulate Primary Outage

Scale down the Primary Kafka brokers and Connect worker to simulate a cluster crash:

```bash
kubectl -n confluent --context kind-primary scale statefulset/kafka --replicas=0
kubectl -n confluent --context kind-primary scale statefulset/connect --replicas=0
```

Verify the brokers and Connect are gone:

```bash
kubectl -n confluent --context kind-primary get pods -l app=kafka
kubectl -n confluent --context kind-primary get pods -l app=connect
```

> **Note**: The KRaft controller and other components (Schema Registry, Control Center) remain running. In a real disaster, the entire cluster would be unreachable. We also scale down Connect to prevent it from reconnecting when Kafka recovers — active consumer groups on `confluent.connect-offsets` would block the `truncate-and-restore` operation in Phase 3.

### Step 2.2: Stop the Schema Exporter

```bash
kubectl -n confluent --context kind-primary delete -f infra/primary/schema-exporter.yaml --ignore-not-found
```

> **Note**: In a real disaster where the Primary is unreachable, the exporter would fail on its own. You can skip this step if the Primary is truly down.

### Step 2.3: Failover Mirror Topics on Secondary

Failover the mirror topics on the Secondary cluster. This promotes them to regular writable topics even though the Primary is unreachable:

```bash
kafka-mirrors --bootstrap-server secondary-control-plane:30192 \
  --command-config etc/scenario3/secondary-client.properties \
  --failover \
  --link bidirectional-link
```

Verify the topics are promoted:

```bash
kafka-mirrors --bootstrap-server secondary-control-plane:30192 \
  --command-config etc/scenario3/secondary-client.properties \
  --describe --links bidirectional-link
```

The mirror topics should no longer appear (they are now regular topics). You can also verify in Control Center on the Secondary cluster -- the mirror icon should disappear from `product-pageviews`.

> **Important**: Unlike `reverse-and-start-mirror`, the `failover` operation does **not** guarantee that all data has been replicated. Any records that were in-flight or not yet replicated at the time of the outage will be lost (this gap defines the RPO). The cluster link itself remains intact for later use with `truncate-and-restore`.

### Step 2.4: Deploy Connector on Secondary

Deploy the same connector configuration to the Secondary cluster to resume data production:

```bash
kubectl -n confluent --context kind-secondary apply -f infra/datagen-connector.yaml
```

Verify:

```bash
kubectl -n confluent --context kind-secondary get connector
```

The Secondary cluster is now the active cluster, producing data.

---

## Phase 3: Failback with `truncate-and-restore`

When the Primary cluster recovers, `truncate-and-restore` simplifies the failback process dramatically. Instead of manually deleting topics and re-creating them as mirrors (as in [Scenario 2](Scenario2.md)), this single operation:

1. **Truncates** any divergent records on the Primary's topics (records written after the failover point that may differ from the Secondary)
2. **Converts** the Primary's topics back to mirror topics
3. **Begins syncing** from the Secondary (now the active cluster)

After the topics are synced, `reverse-and-start-mirror` swaps the roles back to the original topology.

### Step 3.1: Restore the Primary Cluster

Scale the Primary Kafka brokers back up:

```bash
kubectl -n confluent --context kind-primary scale statefulset/kafka --replicas=3
```

Wait for all brokers to be ready:

```bash
kubectl -n confluent --context kind-primary wait pod/kafka-0 pod/kafka-1 pod/kafka-2 \
  --for=condition=Ready --timeout=300s
```

Verify all pods are running:

```bash
kubectl -n confluent --context kind-primary get pods -l app=kafka
```

### Step 3.2: Stop the Connector on Secondary

> **Important**: Stop production **before** restoring mirrors on Primary. This ensures no new data is written while the truncation and sync are in progress.

```bash
kubectl -n confluent --context kind-secondary delete -f infra/datagen-connector.yaml
```

### Step 3.3: Truncate and Restore on Primary

This is the key step. The `truncate-and-restore` operation runs on the Primary cluster via the `bidirectional-link`, using the direction that connects to the Secondary (where the source topics now live):

```bash
kafka-mirrors --bootstrap-server primary-control-plane:30092 \
  --command-config etc/scenario3/primary-client.properties \
  --truncate-and-restore \
  --link bidirectional-link
```

> **What happens under the hood**: The operation goes through the following state progression:
>
> 1. `PendingSetupForRestoreMirror` -- The link reconciles offsets between Primary and Secondary to determine what needs to be truncated.
> 2. `PendingRestoreMirror` -- The link truncates the divergent records on Primary.
> 3. `ACTIVE` -- The topic is now an active mirror topic, syncing from the Secondary.

Monitor the state transition:

```bash
kafka-mirrors --bootstrap-server primary-control-plane:30092 \
  --command-config etc/scenario3/primary-client.properties \
  --describe --links bidirectional-link
```

Wait until both mirror topics reach the `ACTIVE` state. This typically takes 30-60 seconds.

### Step 3.4: Wait for Data to Sync

Once the mirror topics are `ACTIVE`, wait for them to catch up with the Secondary's data:

```bash
kafka-mirrors --bootstrap-server primary-control-plane:30092 \
  --command-config etc/scenario3/primary-client.properties \
  --describe \
  --topics product-pageviews
```

Wait until the mirror lag reaches zero or near-zero for all partitions. This means the Primary has a complete copy of the Secondary's data.

### Step 3.5: Reverse the Mirror Direction

Now that the Primary is in sync, use `reverse-and-start` to restore the original topology. This operation atomically swaps the roles:

- Primary's mirror topics become **source** topics (writable)
- Secondary's source topics become **mirror** topics (read-only, syncing from Primary)

```bash
kafka-mirrors --bootstrap-server primary-control-plane:30092 \
  --command-config etc/scenario3/primary-client.properties \
  --reverse-and-start \
  --topics product-pageviews,confluent.connect-offsets \
  --link bidirectional-link
```

Verify the reversal completed. On the Primary, the topics should now be source topics:

```bash
confluent login --url https://localhost:30080 --certificate-only

confluent kafka topic list --url https://localhost:30080/kafka
```

On the Secondary, the topics should now be mirror topics:

```bash
kafka-mirrors --bootstrap-server secondary-control-plane:30192 \
  --command-config etc/scenario3/secondary-client.properties \
  --describe --links bidirectional-link
```

You should see `product-pageviews` and `confluent.connect-offsets` listed as `ACTIVE` mirror topics on the Secondary.

> **Note**: The `reverse-and-start-mirror` operation achieves **RPO 0** because it ensures all data and consumer offsets are fully replicated before reversing the roles. This is why we wait for the mirror lag to reach zero before executing it.

### Step 3.6: Restore Schema Exporter

Re-establish schema linking from Primary to Secondary:

```bash
kubectl -n confluent --context kind-primary apply -f infra/primary/schema-exporter.yaml
```

Verify:

```bash
kubectl -n confluent --context kind-primary get schemaexporter
```

### Step 3.7: Restore Connect on Primary

Scale Connect back up now that the original topology is restored:

```bash
kubectl -n confluent --context kind-primary scale statefulset/connect --replicas=1
```

Wait for Connect to be ready:

```bash
kubectl -n confluent --context kind-primary wait pod/connect-0 \
  --for=condition=Ready --timeout=600s
```

### Step 3.8: Deploy Connector on Primary

Resume data production on the Primary cluster:

```bash
kubectl -n confluent --context kind-primary apply -f infra/datagen-connector.yaml
```

### Step 3.9: Verify
Check Control Center on both clusters to confirm data is flowing from Primary to Secondary again.

The environment is now fully restored to the original topology using `truncate-and-restore` and `reverse-and-start-mirror`, without any manual topic deletion.

---

## Comparison with Scenario 2

| Aspect | Scenario 2 (Unidirectional) | Scenario 3 (Bidirectional) |
| -------- | --------------------------- | -------------------------- |
| **Link type** | Two separate unidirectional links (CfK-managed) | One bidirectional link (CLI-managed) |
| **Failback method** | Delete topics, re-create as mirrors | `truncate-and-restore` (no deletion needed) |
| **Topic deletion** | Required on both clusters during failback | Not required |
| **Data integrity** | Manual offset management | Automatic offset reconciliation |
| **Operator support** | Fully declarative via CfK CRs | `confluent` CLI + `kafka-mirrors` (invisible to CfK) |
| **Complexity** | More manual steps, more room for error | Fewer steps, automated by Kafka |

---

## Warnings and Caveats

> **Not Managed by CfK**: Cluster links created via the `confluent` CLI are invisible to the CfK operator. `kubectl get clusterlink` will return "No resources found". You must use the `confluent` CLI and `kafka-mirrors` CLI to inspect, modify, or delete them.

> **State Drift Risk**: If someone applies CfK `ClusterLink` CRs while CLI-managed links exist, the operator and manual configuration may conflict. Avoid mixing CfK-managed and CLI-managed cluster links on the same cluster.

> **Bidirectional Link Requirement**: The `truncate-and-restore` and `reverse-and-start-mirror` operations are **only available with bidirectional cluster links** (`link.mode=BIDIRECTIONAL`). They will not work with standard unidirectional links.

> **Consumer Group Conflicts**: The `truncate-and-restore` operation will be blocked if there are active consumers with conflicting consumer group IDs on the topics. Ensure all consumers (including connectors) are stopped before executing this operation.

> **Failover vs Reverse**: Use `failover` when the source cluster is unavailable (emergency). Use `reverse-and-start` when both clusters are reachable (planned switchover). The `failover` operation does not guarantee RPO 0, while `reverse-and-start` does.

> **Schema Linking**: Schema linking is still managed by CfK via the `SchemaExporter` CR. Only cluster links and mirror topics are managed via the CLI.

---

## Cleanup

To restore the environment to the DR Demo Setup state with CfK-managed cluster links:

```bash
# 1. Delete connector (wherever it is running)
kubectl -n confluent --context kind-primary delete -f infra/datagen-connector.yaml --ignore-not-found
kubectl -n confluent --context kind-secondary delete -f infra/datagen-connector.yaml --ignore-not-found

# 2. Delete schema exporter
kubectl -n confluent --context kind-primary delete -f infra/primary/schema-exporter.yaml --ignore-not-found

# 3. Scale primary back up (if scaled down)
kubectl -n confluent --context kind-primary scale statefulset/kafka --replicas=3
kubectl -n confluent --context kind-primary scale statefulset/connect --replicas=1
kubectl -n confluent --context kind-primary wait pod/kafka-0 pod/kafka-1 pod/kafka-2 \
  --for=condition=Ready --timeout=300s
kubectl -n confluent --context kind-primary wait pod/connect-0 \
  --for=condition=Ready --timeout=600s

# 4. Delete CLI-managed bidirectional cluster links
confluent login --url https://localhost:30180 --certificate-only
confluent kafka link delete bidirectional-link --force --url https://localhost:30180/kafka

confluent login --url https://localhost:30080 --certificate-only
confluent kafka link delete bidirectional-link --force --url https://localhost:30080/kafka

# 5. Delete topics on Secondary (may have been promoted during failover)
confluent login --url https://localhost:30180 --certificate-only
confluent kafka topic delete product-pageviews --force --url https://localhost:30180/kafka
confluent kafka topic delete confluent.connect-offsets --force --url https://localhost:30180/kafka

# 6. Re-apply the topic CR on Primary
kubectl -n confluent --context kind-primary apply -f infra/primary/topics.yaml

# 7. Re-apply CfK-managed cluster link on Secondary
kubectl -n confluent --context kind-secondary apply -f infra/secondary/cluster-link.yaml

# 8. Re-apply schema exporter on Primary
kubectl -n confluent --context kind-primary apply -f infra/primary/schema-exporter.yaml

# 9. Re-deploy connector on Primary
kubectl -n confluent --context kind-primary apply -f infra/datagen-connector.yaml
```

Verify:

```bash
kubectl -n confluent --context kind-secondary get clusterlink
kubectl -n confluent --context kind-primary get schemaexporter
kubectl -n confluent --context kind-primary get connector
```

> **Tip**: If cleanup does not restore the environment cleanly, perform a [Full Environment Cleanup](README.md#full-environment-cleanup) and start fresh.

### Quick Cleanup

For a complete environment reset:

```bash
./scripts/teardown.sh
```
