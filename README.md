# CfK Disaster Recovery Playground

This project provides a playground environment to test disaster recovery scenarios using **Confluent for Kubernetes (CfK)**. The setup includes two independent Kubernetes clusters (primary and secondary) connected via a shared Docker network.

## Overview

The playground consists of:

- **Primary cluster**: Active site generating traffic via a Datagen connector.
- **Secondary cluster**: Standby site mirroring data via Cluster Linking.

Both clusters run the full Confluent Platform stack (KRaft, Kafka, Schema Registry, Connect, REST Proxy, Control Center).

## Prerequisites

- `docker`
- `kind`
- `kubectl`
- `helm`
- `openssl` and `keytool` (included with Java JDK)

## Setup Instructions

### 1. Create the Shared Network

A shared Docker network allows the Kind cluster nodes to reach each other directly.

```bash
docker network create kind-shared
```

### 2. Create the Kind Clusters

Deploy two independent clusters:

```bash
# Create primary cluster
kind create cluster --name primary --image kindest/node:v1.31.0 --config infra/primary/kind-primary.yaml
docker network connect kind-shared primary-control-plane

# Create secondary cluster
kind create cluster --name secondary --image kindest/node:v1.31.0 --config infra/secondary/kind-secondary.yaml
docker network connect kind-shared secondary-control-plane
```

### 3. Generate TLS Certificates & Secrets

mTLS is used across all components. The CA config lives in `certs/ca/openssl-ca.cnf`.

```bash
# Generate certificates for all components
./generate_certificates.sh

# Create Kubernetes secrets in both clusters
./create_secrets.sh
```

### 4. Deploy the CfK Operator

Install the operator in both clusters:

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

# Primary
helm upgrade --install operator confluentinc/confluent-for-kubernetes \
  --namespace confluent --create-namespace --kube-context kind-primary

# Secondary
helm upgrade --install operator confluentinc/confluent-for-kubernetes \
  --namespace confluent --create-namespace --kube-context kind-secondary
```

### 5. Deploy Confluent Platform

Apply the platform manifests and `KafkaRestClass` resources. The KafkaRestClass tells the operator how to access the Kafka Admin REST API for managing topics and cluster links.

```bash
# Primary
kubectl -n confluent --context kind-primary apply -f infra/primary/primary.yaml
kubectl -n confluent --context kind-primary apply -f infra/primary/primary-rest-class.yaml

# Secondary
kubectl -n confluent --context kind-secondary apply -f infra/secondary/secondary.yaml
kubectl -n confluent --context kind-secondary apply -f infra/secondary/secondary-rest-class.yaml
```

### 6. Wait for All Pods

Wait for all pods to be `Running` and `READY` before proceeding:

```bash
watch kubectl -n confluent --context kind-primary get pods
watch kubectl -n confluent --context kind-secondary get pods
```

> **Tip**: This can take several minutes, especially the first time as images are pulled.

#### Access Control Center

Add to `/etc/hosts`:

```
127.0.0.1 controlcenter-ng.confluent.svc.cluster.local
```

**Primary** (port 9021):

```bash
kubectl -n confluent --context kind-primary port-forward svc/controlcenter-ng 9021:9021 > /dev/null 2>&1 &
```

> URL: [https://controlcenter-ng.confluent.svc.cluster.local:9021](https://controlcenter-ng.confluent.svc.cluster.local:9021)

**Secondary** (port 9022):

```bash
kubectl -n confluent --context kind-secondary port-forward svc/controlcenter-ng 9022:9021 > /dev/null 2>&1 &
```

> URL: [https://controlcenter-ng.confluent.svc.cluster.local:9022](https://controlcenter-ng.confluent.svc.cluster.local:9022)

---

## 🚀 DR Demo Setup

### 1. Deploy Topic, Schema, and Datagen Connector (Primary)

Create the topic, proactively register the schema with FULL compatibility, and start producing data:

```bash
kubectl -n confluent --context kind-primary apply -f infra/primary/product-pageviews-schema.yaml
kubectl -n confluent --context kind-primary apply -f infra/primary/topics.yaml
kubectl -n confluent --context kind-primary apply -f infra/datagen-connector.yaml
```

Verify the connector is running:

```bash
kubectl -n confluent --context kind-primary get connector
```

### 2. Setup Cluster Linking & Schema Linking (Secondary)

Cluster metadata and topic data are mirrored via Kafka Cluster Linking. Schemas are mirrored via **Schema Linking**.

The Primary cluster pushes schemas to the Secondary Schema Registry (NodePort `30081`) and Kafka data via NodePort `30092`.

1. **On Secondary cluster**, expose the Schema Registry, create the link, and **then deploy Connect**:

   *Note: usage of `connect-offsets` mirror topic requires that the topic exists before Connect starts. Therefore, we deploy Connect AFTER establishing the link.*

```bash
# Expose SR for incoming replication
kubectl -n confluent --context kind-secondary apply -f infra/secondary/cluster-link-rest-class.yaml
kubectl -n confluent --context kind-secondary apply -f infra/secondary/cluster-link.yaml
```

Wait until the connect topic is created in the secondary cluster, and then deploy Connect:

```bash
# Deploy Connect (deferred to ensure mirror topic usage)
kubectl -n confluent --context kind-secondary apply -f infra/secondary/connect.yaml
```

1. **On Primary cluster**, start the schema replication:

```bash
kubectl -n confluent --context kind-primary apply -f infra/primary/schema-exporter.yaml
```

### 3. Verification

Verify the cluster link and schema exporter:

```bash
# Check Kafka Link
kubectl -n confluent --context kind-secondary get clusterlink

# Check Schema Exporter
kubectl -n confluent --context kind-primary get schemaexporter
```

If you now connect to the Control Center of the secondary cluster, you will see a "product-pageviews" topic with data coming from the primary cluster.

### 4. DR Failover Simulation

To simulate a disaster recovery scenario where the Primary cluster becomes unavailable, we will perform a failover to the Secondary cluster.

The workflow involves:

1. **Stop the primary cluster** (simulated outage).
2. **Failover the topic** by deleting the Cluster Link, which promotes the mirror topic to a writable topic.
3. **Deploy the connector** to the Secondary cluster to resume production.

**Steps:**

1. **Simulate Outage (Optional)**: Scale down the primary Kafka brokers to simulate a crash.

```bash
kubectl -n confluent --context kind-primary scale statefulset/kafka --replicas=0
```

1. **Trigger Failover**: Delete the Cluster Link CR. This stops mirroring and promotes `product-pageviews` to a read-write topic on the Secondary cluster.

```bash
kubectl -n confluent --context kind-secondary delete -f infra/secondary/cluster-link.yaml
```

After some moments, the mirror icon will dissapear from the Topic details page in Control Center, and that means that the topics have transitioned from Mirror Topics to normal topics.

1. **Start Production on Secondary**: Deploy the same Datagen connector configuration to the Secondary cluster.

```bash
kubectl -n confluent --context kind-secondary apply -f infra/datagen-connector.yaml
```

1. **Verify**: Check that data is being produced in the Secondary cluster.

```bash
kubectl -n confluent --context kind-secondary get connector
```

---

## 🧹 Cleanup

```bash
kind delete cluster --name primary
kind delete cluster --name secondary
docker network rm kind-shared
rm -rf certs/
```
