# Scenario 2: Unidirectional Cluster Linking -- Failover and Failback

## Overview

This scenario simulates a **temporary failover** from the Primary cluster to the Secondary cluster, followed by a **failback** to the original Primary once it recovers. All cluster links are managed declaratively using CfK Custom Resources.

This is appropriate when:

- The Primary cluster suffers a temporary outage (e.g., maintenance, transient failure).
- You want to resume operations on the Primary cluster after it recovers.
- You prefer to manage all infrastructure declaratively via CfK CRs.

```
Normal:     Primary ──────────► Secondary (mirror)
Failover:   Primary (DOWN)       Secondary (active)
Failback:   Primary (mirror) ◄── Secondary (active)
Restored:   Primary ──────────► Secondary (mirror)
```

## Prerequisites

- You have completed the [DR Demo Setup](README.md) sections 1 through 3 (Verification).
- The cluster link is active and data is flowing from Primary to Secondary.
- The schema exporter is running and schemas are replicated.
- The [TLS environment variables](README.md#access-via-confluent-cli) are set in your shell.

Verify the current state:

```bash
kubectl -n confluent --context kind-secondary get clusterlink
kubectl -n confluent --context kind-primary get schemaexporter
kubectl -n confluent --context kind-primary get connector
```

---

## Phase 1: Failover

### Step 1.1: Simulate Primary Outage

Stop the Schema Exporter:

```bash
kubectl -n confluent --context kind-primary delete -f infra/primary/schema-exporter.yaml
```

> **Note**: In a real disaster where the Primary is unreachable, the exporter would fail on its own. Skip this step if the Primary is truly down.

And scale down the Primary Kafka brokers to simulate a cluster crash:

```bash
kubectl -n confluent --context kind-primary scale statefulset/kafka --replicas=0
```

Verify the brokers are gone:

```bash
kubectl -n confluent --context kind-primary get pods -l app=kafka
```

### Step 1.2: Promote Mirror Topics

Delete the ClusterLink CR on the Secondary cluster to promote all mirror topics to writable:

```bash
kubectl -n confluent --context kind-secondary delete -f infra/secondary/cluster-link.yaml
```

Wait for the promotion to complete:

```bash
# Should return "No resources found in confluent namespace."
kubectl -n confluent --context kind-secondary get clusterlink
```

> **Verification**: Open Control Center on the Secondary cluster ([https://controlcenter-ng.confluent.svc.cluster.local:9022](https://controlcenter-ng.confluent.svc.cluster.local:9022)). The mirror icon should disappear from `product-pageviews`.

### Step 1.3: Deploy Connector on Secondary

```bash
kubectl -n confluent --context kind-secondary apply -f infra/datagen-connector.yaml
```

Verify:

```bash
kubectl -n confluent --context kind-secondary get connector
```

### Step 1.4: Adopt Topic Declaratively on Secondary

Apply the KafkaTopic CR to manage the `product-pageviews` topic declaratively on Secondary:

```bash
kubectl -n confluent --context kind-secondary apply -f infra/secondary/topics.yaml
```

This allows the topic to be managed via CfK CRs going forward.

The Secondary cluster is now the active cluster, producing data.

---

## Phase 2: Prepare for Failback

### Step 2.1: Restore the Primary Cluster

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

### Step 2.2: Delete Existing Topics on Primary

> **Warning -- Destructive Operation**: The `product-pageviews` topic still exists on the Primary as a regular (non-mirror) topic. It must be deleted before the reverse cluster link can create a mirror topic with the same name. **Data on this topic from before the outage will be lost on the Primary side** (the Secondary has the up-to-date copy).

Delete the KafkaTopic CR (the `delete-on-cr-removal` annotation ensures the underlying topic is also deleted):

```bash
kubectl -n confluent --context kind-primary delete -f infra/primary/topics.yaml
```

Delete the `confluent.connect-offsets` internal topic using the `confluent` CLI (this topic is not managed by a KafkaTopic CR):

```bash
# Login to the primary cluster MDS
confluent login --url https://localhost:30080 --certificate-only

# Delete confluent.connect-offsets topic
confluent kafka topic delete confluent.connect-offsets --force --url https://localhost:30080/kafka
```

Verify in Control Center that the topics that need to be replicated from the secondary cluster (`product-pageviews` and `confluent.connect-offsets`) have been deleted.

### Step 2.3: Deploy Reverse Cluster Link on Primary

Apply the reverse KafkaRestClass and ClusterLink CRs that point Primary to Secondary:

```bash
kubectl -n confluent --context kind-primary apply -f infra/primary/reverse-cluster-link-rest-class.yaml
kubectl -n confluent --context kind-primary apply -f infra/primary/reverse-cluster-link.yaml
```

Wait for the cluster link to become active and mirror topics to appear:

```bash
kubectl -n confluent --context kind-primary get clusterlink
```

The status should show the link as `READY`. The `product-pageviews` and `confluent.connect-offsets` topics will be created as mirror topics on the Primary.

> **Note**: This may take a minute or two for the operator to reconcile and establish the link.

### Step 2.4: Set Up Reverse Schema Export

Start exporting schemas from Secondary back to Primary:

```bash
kubectl -n confluent --context kind-secondary apply -f infra/secondary/schema-exporter.yaml
```

Verify:

```bash
kubectl -n confluent --context kind-secondary get schemaexporter
```

### Step 2.5: Wait for Data to Sync

The Primary is now mirroring data from the Secondary. Wait for the mirror topics to catch up.

You can monitor the sync progress in Control Center on the Primary cluster ([https://controlcenter-ng.confluent.svc.cluster.local:9021](https://controlcenter-ng.confluent.svc.cluster.local:9021)), or check the topic details using the `confluent` CLI:

```bash
# Login to the primary cluster MDS (if not already logged in)
confluent login --url https://localhost:30080 --certificate-only

# Check topic details
confluent kafka topic describe product-pageviews --url https://localhost:30080/kafka
```

Wait until the Primary mirror topic offsets match the Secondary source topic offsets.

---

## Phase 3: Failback

### Step 3.1: Stop the Connector on Secondary

> **Important**: Stop production **before** promoting the mirror topics on Primary. This ensures no data is lost during the transition.

```bash
kubectl -n confluent --context kind-secondary delete -f infra/datagen-connector.yaml
```

### Step 3.2: Wait for Replication Lag to Reach Zero

After stopping the connector, wait for the last records to be replicated to Primary. You can check the consumer lag or simply wait ~30 seconds for the sync to complete.

### Step 3.3: Delete the Reverse Schema Exporter

```bash
kubectl -n confluent --context kind-secondary delete -f infra/secondary/schema-exporter.yaml
```

### Step 3.4: Promote Mirror Topics on Primary

Delete the reverse ClusterLink CR to promote the mirror topics on Primary back to writable:

```bash
kubectl -n confluent --context kind-primary delete -f infra/primary/reverse-cluster-link.yaml
```

Wait for promotion:

```bash
# Should return "No resources found"
kubectl -n confluent --context kind-primary get clusterlink
```

### Step 3.5: Clean Up Reverse REST Class

```bash
kubectl -n confluent --context kind-primary delete -f infra/primary/reverse-cluster-link-rest-class.yaml
```

### Step 3.6: Delete Topics on Secondary

The `product-pageviews` and `confluent.connect-offsets` topics exist on Secondary as regular topics (promoted during Phase 1). They must be deleted before the forward cluster link can re-create them as mirror topics.

Delete the `product-pageviews` topic by deleting its KafkaTopic CR (the `delete-on-cr-removal` annotation ensures the underlying topic is also deleted):

```bash
kubectl -n confluent --context kind-secondary delete -f infra/secondary/topics.yaml
```

Delete the `confluent.connect-offsets` internal topic using the `confluent` CLI:

```bash
# Login to the secondary cluster MDS
confluent login --url https://localhost:30180 --certificate-only

# Delete confluent.connect-offsets topic
confluent kafka topic delete confluent.connect-offsets --force --url https://localhost:30180/kafka
```

### Step 3.7: Restore the Original Forward Cluster Link

Re-establish the original cluster link from Primary to Secondary:

```bash
kubectl -n confluent --context kind-secondary apply -f infra/secondary/cluster-link.yaml
```

Wait for the link to become active:

```bash
kubectl -n confluent --context kind-secondary get clusterlink
```

### Step 3.8: Restore the Original Schema Exporter

```bash
kubectl -n confluent --context kind-primary apply -f infra/primary/schema-exporter.yaml
```

Verify:

```bash
kubectl -n confluent --context kind-primary get schemaexporter
```

### Step 3.9: Re-apply Topic CR on Primary

Since the topic was deleted in Phase 2, re-apply the KafkaTopic CR so it is managed declaratively again:

```bash
kubectl -n confluent --context kind-primary apply -f infra/primary/topics.yaml
```

### Step 3.10: Deploy the Connector on Primary

```bash
kubectl -n confluent --context kind-primary apply -f infra/datagen-connector.yaml
```

### Step 3.11: Verify

```bash
# Connector producing on Primary
kubectl -n confluent --context kind-primary get connector

# Cluster link active on Secondary
kubectl -n confluent --context kind-secondary get clusterlink

# Schema exporter running on Primary
kubectl -n confluent --context kind-primary get schemaexporter
```

Check Control Center on both clusters to confirm data is flowing from Primary to Secondary again.

---

## Warnings and Caveats

> **Two Data-Loss Windows**: Data loss can occur during both the initial failover (in-flight records not yet replicated) and during the failback transition (if the connector is not stopped before promoting). Always stop production before promoting mirror topics during failback.

> **Topic Deletion on Primary**: During Phase 2, the existing `product-pageviews` and `confluent.connect-offsets` topics on Primary must be deleted before the reverse cluster link can create mirror topics. This is a destructive operation. The data is safe on the Secondary, but the Primary's copy is lost.

> **Topic Deletion on Secondary**: During Phase 3 (Step 3.6), the topics on Secondary must also be deleted before the forward cluster link can re-create them as mirror topics. These topics were adopted declaratively during Phase 1 (Step 1.4) and promoted to regular topics during failover.

> **Schema Conflicts**: If schemas are modified on the Secondary during the failover period, the reverse schema export to Primary may encounter compatibility conflicts. In this demo we do not modify schemas, so this is not an issue. In production, coordinate schema changes carefully during the failover window.

> **Declarative Management**: Throughout this process, all cluster links, schema exporters, and the `product-pageviews` topic are managed via CfK CRs (`kubectl apply/delete`). The `KafkaTopic` CRs include the `delete-on-cr-removal` annotation to ensure topics are deleted when CRs are removed. The `confluent.connect-offsets` internal topic is deleted using the `confluent` CLI.

---

## Cleanup

If the failback process (Phase 3) was completed successfully, the environment is already restored to the DR Demo Setup state and no cleanup is needed.

If you stopped mid-scenario and need to reset, perform a [Full Environment Cleanup](README.md#full-environment-cleanup) and start fresh. This is the most reliable way to restore the environment since the scenario involves multiple topic deletions and cluster link changes that can leave the system in various intermediate states.
