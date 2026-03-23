# Scenario 1: Unidirectional Cluster Linking -- Failover and Stay

## Overview

This scenario simulates a **permanent failover** from the Primary cluster to the Secondary cluster. The Primary cluster goes down (simulated outage), and the Secondary cluster is promoted to become the new active cluster. There is no plan to return to the original Primary.

This is the simplest DR scenario and is appropriate when:

- The Primary cluster has suffered an unrecoverable failure.
- You want to validate that the Secondary cluster can take over seamlessly.

```
┌─────────────────┐         ┌─────────────────┐
│  PRIMARY (DOWN)  │  ──X──  │  SECONDARY       │
│                  │         │  (Promoted to    │
│  Kafka: OFF      │         │   Active)        │
│  Connect: OFF    │         │  Kafka: ON       │
│                  │         │  Connect: ON     │
└─────────────────┘         └─────────────────┘
```

## Prerequisites

- You have completed the [DR Demo Setup](README.md) sections 1 through 3 (Verification).
- The cluster link is active and data is flowing from Primary to Secondary.
- The schema exporter is running and schemas are replicated.
- The [TLS environment variables](README.md#access-via-confluent-cli) are set in your shell.

Verify the current state:

```bash
# Cluster link should be active
kubectl -n confluent --context kind-secondary get clusterlink

# Schema exporter should be running
kubectl -n confluent --context kind-primary get schemaexporter

# Connector should be producing data
kubectl -n confluent --context kind-primary get connector
```

---

## Step 1: Simulate Primary Outage

Scale down the Primary Kafka brokers to simulate a cluster crash:

```bash
kubectl -n confluent --context kind-primary scale statefulset/kafka --replicas=0
```

Verify the brokers are gone:

```bash
kubectl -n confluent --context kind-primary get pods -l app=kafka
```

> **Note**: The KRaft controller remains running. In a real disaster, the entire cluster would be unreachable.

---

## Step 2: Stop the Schema Exporter

Delete the SchemaExporter CR on the Primary cluster:

```bash
kubectl -n confluent --context kind-primary delete -f infra/primary/schema-exporter.yaml
```

> **Note**: If the Primary cluster were truly unreachable, this step would not be possible. The exporter would simply fail on its own since it cannot reach the source Schema Registry. In a real scenario, you can skip this step.

---

## Step 3: Promote Mirror Topics (Failover)

Delete the ClusterLink CR on the Secondary cluster. This triggers CfK to call the failover API, which promotes all mirror topics to writable (regular) topics:

```bash
kubectl -n confluent --context kind-secondary delete -f infra/secondary/cluster-link.yaml
```

Wait for the promotion to complete (~30 seconds):

```bash
# Should return "No resources found"
kubectl -n confluent --context kind-secondary get clusterlink
```

> **Verification**: Open Control Center on the Secondary cluster ([https://controlcenter-ng.confluent.svc.cluster.local:9022](https://controlcenter-ng.confluent.svc.cluster.local:9022)). The mirror icon should disappear from the `product-pageviews` topic, indicating it is now a regular writable topic.

---

## Step 4: Deploy the Datagen Connector on Secondary

Deploy the same connector configuration to the Secondary cluster to resume data production:

```bash
kubectl -n confluent --context kind-secondary apply -f infra/datagen-connector.yaml
```

Verify the connector is running:

```bash
kubectl -n confluent --context kind-secondary get connector
```

Check Control Center on the Secondary cluster to confirm new messages are appearing in the `product-pageviews` topic.

---

## Step 5: Manage Resources Declaratively on Secondary

Now that the Secondary cluster is the active cluster, you can manage topics declaratively using CfK on the secondary:

```bash
kubectl -n confluent --context kind-secondary apply -f infra/secondary/topics.yaml
```

This applies the `KafkaTopic` CR for `product-pageviews` on the secondary cluster, allowing CfK to manage its lifecycle going forward.

---

## Warnings and Caveats

> **Data Loss (RPO)**: Any records that were in-flight or not yet replicated at the time of the outage will be lost. The Recovery Point Objective (RPO) depends on the replication lag of the cluster link at the moment of failure.

> **Duplicate Processing**: The `confluent.connect-offsets` mirror topic was promoted along with `product-pageviews`. Since consumer offset sync was enabled (`consumer.offset.sync.enable: "true"`), the connector on the Secondary cluster will resume close to where the Primary left off. However, some duplicate processing is possible for records that were committed on the Primary but whose offsets were not yet synced.

> **Schema State**: Schemas exported via Schema Linking were written to the Secondary Schema Registry's default context (because the exporter used `contextType: NONE`). After failover, the Datagen connector on Secondary will register and use schemas normally -- no additional schema configuration is needed.

> **No Return Path**: This scenario does not provide a way to return to the Primary cluster. If you need failback capability, see [Scenario 2](Scenario2.md) or [Scenario 3](Scenario3.md).

---

## Cleanup

To restore the environment to the DR Demo Setup state (ready for another scenario):

```bash
# 1. Delete the connector on Secondary
kubectl -n confluent --context kind-secondary delete -f infra/datagen-connector.yaml

# 2. Delete the declarative topic on Secondary (if applied in Step 5)
kubectl -n confluent --context kind-secondary delete -f infra/secondary/topics.yaml --ignore-not-found

# 3. Scale Primary Kafka back up
kubectl -n confluent --context kind-primary scale statefulset/kafka --replicas=3

# 4. Wait for Primary Kafka brokers to be ready
kubectl -n confluent --context kind-primary wait pod/kafka-0 pod/kafka-1 pod/kafka-2 \
  --for=condition=Ready --timeout=300s

# 5. Delete the promoted mirror topics on Secondary (required before re-creating the cluster link)
# Login to the secondary cluster MDS
confluent login --url https://localhost:30180 --certificate-only

# Delete topics
confluent kafka topic delete product-pageviews --force --url https://localhost:30180/kafka
confluent kafka topic delete confluent.connect-offsets --force --url https://localhost:30180/kafka

# 6. Re-apply the cluster link on Secondary
kubectl -n confluent --context kind-secondary apply -f infra/secondary/cluster-link.yaml

# 7. Re-apply the schema exporter on Primary
kubectl -n confluent --context kind-primary apply -f infra/primary/schema-exporter.yaml

# 8. Re-deploy the connector on Primary
kubectl -n confluent --context kind-primary apply -f infra/datagen-connector.yaml
```

> **Note**: Step 5 uses the `confluent` CLI to delete topics. You must first login to the secondary cluster's MDS endpoint (`https://localhost:30180`) using the `kafka` mTLS certificate. See [MDS Users](README.md#mds-users) for details.

Verify the environment is restored:

```bash
kubectl -n confluent --context kind-secondary get clusterlink
kubectl -n confluent --context kind-primary get schemaexporter
kubectl -n confluent --context kind-primary get connector
```

> **Tip**: If cleanup does not restore the environment cleanly, perform a [Full Environment Cleanup](README.md#full-environment-cleanup) and start fresh.
