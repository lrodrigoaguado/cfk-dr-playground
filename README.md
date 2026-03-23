# CfK Disaster Recovery Playground

This project provides a playground environment to test disaster recovery scenarios using **Confluent for Kubernetes (CfK)**. The setup includes two independent Kubernetes clusters (primary and secondary) connected via a shared Docker network.

## Overview

The playground consists of:

- **Primary cluster**: Active site generating traffic via a Datagen connector.
- **Secondary cluster**: Standby site mirroring data via Cluster Linking.

Both clusters run the full Confluent Platform stack (KRaft, Kafka, Schema Registry, Connect, REST Proxy, Control Center) with **mTLS** authentication for all component-to-component communication and a minimal **MDS** (Metadata Service) for `confluent` CLI access.

## Prerequisites

- `docker`
- `kind`
- `kubectl`
- `helm`
- `openssl` and `keytool` (included with Java JDK)
- `confluent` CLI v4.23.0+ ([install guide](https://docs.confluent.io/confluent-cli/current/install.html)) -- needed for Scenario 3 and some administrative operations. Certificate-based login requires v4.23.0+.
- Confluent Platform or Apache Kafka CLI tools (for Scenario 3 only -- provides `kafka-cluster-links` and `kafka-mirrors` commands)

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

### 3. Generate TLS Certificates, MDS Keys & Secrets

TLS is used across all components for transport encryption and mutual authentication. An RSA key pair is generated for MDS token signing.

```bash
# Generate certificates and MDS token key pair
./generate_certificates.sh

# Create Kubernetes secrets (TLS + MDS credentials) in both clusters
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

### 7. Set Environment Variables

Export all required environment variables with a single command:

```bash
source scripts/set-env.sh
```

This sets the TLS certificate paths and cluster IDs needed for the `confluent` CLI and Scenario 3.

#### Access Control Center

Add to `/etc/hosts`:

```
127.0.0.1 primary-control-plane secondary-control-plane controlcenter-ng.confluent.svc.cluster.local
```

> **Why these entries?** `primary-control-plane` and `secondary-control-plane` are Docker container names used by Kind. Adding them to `/etc/hosts` makes them resolvable from your local machine, which is required for the `confluent` CLI and cross-cluster communication. The two clusters use different NodePort ranges (primary: 30080, 30092-30094; secondary: 30180, 30192-30194) to avoid port conflicts on the same loopback address.

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

And, finally, give the `admin`user the appropriate permissions to manage the Clusters in both Control Centers:

```bash
# Primary cluster
kubectl --context kind-primary apply -f infra/primary/rolebindings.yaml

# Secondary cluster
kubectl --context kind-secondary apply -f infra/secondary/rolebindings.yaml
```

> **Login credentials**: Use username `admin` and password `admin-secret`. See [MDS Users](#mds-users) for more details.

#### Access via Confluent CLI

> **Note**: Environment variables should already be set if you ran `source scripts/set-env.sh` in step 7. If you open a new terminal, re-run that command.

Log in to the clusters using certificate-based authentication:

```bash
# Login to primary cluster MDS
confluent login --url https://localhost:30080 --certificate-only

# Login to secondary cluster MDS
confluent login --url https://localhost:30180 --certificate-only
```

After login, you can manage the cluster. The `--url` flag points to the embedded Kafka REST API (primary: `30080/kafka`, secondary: `30180/kafka`):

```bash
confluent kafka topic list --url https://localhost:30080/kafka

confluent kafka topic list --url https://localhost:30180/kafka
```

---

## DR Demo Setup

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

> **Scenario 3 users**: If you plan to run [Scenario 3: Bidirectional Cluster Linking with `truncate-and-restore`](Scenario3.md), skip directly to Scenario 3 now. It creates its own bidirectional cluster link and handles the remaining setup steps internally. Steps 2 and 3 below are only needed for Scenarios 1 and 2.

### 2. Setup Cluster Linking & Schema Linking (Secondary)

Cluster metadata and topic data are mirrored via Kafka Cluster Linking. Schemas are mirrored via **Schema Linking**.

The Primary cluster pushes schemas to the Secondary Schema Registry (NodePort `30081`) and Kafka data via NodePort `30192`.

1. **On Secondary cluster**, create the link and **then deploy Connect**:

   *Note: the `confluent.connect-offsets` mirror topic must exist before Connect starts. Therefore, we deploy Connect AFTER establishing the link.*

```bash
# Create cluster link from primary to secondary
kubectl -n confluent --context kind-secondary apply -f infra/secondary/cluster-link-rest-class.yaml
kubectl -n confluent --context kind-secondary apply -f infra/secondary/cluster-link.yaml
```

Wait until the connect-offsets topic is created in the secondary cluster, and then deploy Connect:

```bash
# Deploy Connect (deferred to ensure mirror topic exists)
kubectl -n confluent --context kind-secondary apply -f infra/secondary/connect.yaml
```

As with the primary cluster, the deployment of the Connect cluster may take some time. Check the Control Center or watch the pods status with:

```bash
watch kubectl -n confluent --context kind-secondary get pods
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

You can also verify using the `confluent` CLI:

```bash
# Login to primary
confluent login --url https://localhost:30080 --certificate-only

# List topics
confluent kafka topic list --url https://localhost:30080/kafka

# Consume some messages
confluent kafka topic consume product-pageviews --from-beginning --limit 5 --url https://localhost:30080/kafka
```

---

## DR Scenarios

After completing the DR Demo Setup above, you can explore the following disaster recovery scenarios. Each scenario assumes you have completed steps 1-3 of the DR Demo Setup and have a working primary cluster with data flowing and a secondary cluster mirroring via Cluster Linking and Schema Linking.

> **Important**: Run only **one scenario at a time**. After completing a scenario, follow its cleanup section to restore the environment before attempting another scenario, or perform a full environment cleanup and start fresh.

| Scenario | Description | Complexity |
|----------|-------------|------------|
| [Scenario 1: Failover and Stay](Scenario1.md) | Permanent failover from primary to secondary. The secondary becomes the new active cluster. | Low |
| [Scenario 2: Failover and Failback (Operator-managed)](Scenario2.md) | Temporary failover to secondary, then failback to primary after recovery. All links managed via CfK CRs. | Medium |
| [Scenario 3: Bidirectional Cluster Linking with `truncate-and-restore`](Scenario3.md) | Bidirectional cluster link using `confluent` CLI. Features `truncate-and-restore` for simplified failback (no manual topic deletion). | High |

---

## MDS Users

The `confluent` CLI authenticates to MDS using the `kafka` mTLS certificate (configured via the `CONFLUENT_PLATFORM_CLIENT_CERT_PATH` / `CONFLUENT_PLATFORM_CLIENT_KEY_PATH` environment variables). No username or password is needed for CLI login.

The following file-based MDS users are configured internally for KafkaRestClass bearer token authentication. They are **not** used for CLI login:

| User | Password | Purpose |
|------|----------|---------|
| `admin` | `admin-secret` | Control Center UI login; fallback for username/password CLI login (if certificate login is unavailable) |
| `kafka` | `kafka-secret` | Kafka REST API (used by KafkaRestClass for CfK-managed resources) |
| `clusterlink` | `link-secret` | Remote cluster link REST operations |

> **Note**: All Confluent Platform components authenticate to each other using mTLS certificates. The certificate CN is mapped to a principal via `principalMappingRules`. Core cluster principals (`kafka`, `kraftcontroller`, `admin`) and cross-cluster principals (`cluster-link`, `clusterlink`) are listed as `superUsers`. Other components (Schema Registry, Connect, REST Proxy, Control Center) get their permissions via CfK auto-generated `ConfluentRolebinding` CRs.

---

## Full Environment Cleanup

Run the automated teardown script:

```bash
./scripts/teardown.sh
```

This will:

- Stop all port-forward processes
- Delete both Kind clusters
- Remove the Docker network
- Clean all generated certificates
- Unset environment variables

**Manual step**: You may also want to remove the `/etc/hosts` entries:

```text
127.0.0.1 primary-control-plane secondary-control-plane controlcenter-ng.confluent.svc.cluster.local
```
