# Scenario 3 Configuration Files

This directory contains configuration files for [Scenario 3: Bidirectional Cluster Linking with truncate-and-restore](../../Scenario3.md).

## Files

### Cluster Link Configuration Files

- **[link-on-secondary.config](link-on-secondary.config)**: Configuration for creating the bidirectional link on the Secondary cluster. Specifies how the Secondary broker connects to the Primary cluster (remote) using mTLS. Paths are broker-internal (resolved inside the Kafka pod).
- **[link-on-primary.config](link-on-primary.config)**: Configuration for creating the bidirectional link on the Primary cluster. Specifies how the Primary broker connects to the Secondary cluster (remote) using mTLS. Paths are broker-internal (resolved inside the Kafka pod).

### Logging Configuration

- **[tools-log4j.properties](tools-log4j.properties)**: Custom Log4j configuration for Kafka CLI tools (`kafka-mirrors`, `kafka-cluster-links`). Sets the log level to ERROR to suppress transient WARN messages during mTLS connections. Used via the `KAFKA_LOG4J_OPTS` environment variable.

### Client Configuration Files

- **[primary-client.properties](primary-client.properties)**: Client configuration to connect to the Primary cluster (used with `kafka-cluster-links` and `kafka-mirrors` CLI tools). Paths are local.
- **[secondary-client.properties](secondary-client.properties)**: Client configuration to connect to the Secondary cluster (used with `kafka-cluster-links` and `kafka-mirrors` CLI tools). Paths are local.

## Authentication

- **Link configs** use **mTLS** (`SSL` security protocol) with broker-internal keystores at `/mnt/sslcerts/`. The broker's Kafka certificate is used for inter-cluster authentication.
- **Client properties** use **mTLS** (`SSL` security protocol) with local keystores at `certs/kafka/`. The `kafka` certificate CN is listed as a superUser on both clusters.
- **`confluent` CLI** uses **mTLS certificates** via `confluent login --certificate-only` (see [MDS Users](../../README.md#mds-users) for details). The `kafka` certificate PEM files are configured via [TLS environment variables](../../README.md#access-via-confluent-cli).

## Usage

Run all commands from the repository root directory to ensure proper path resolution.

**Link creation** (using `kafka-cluster-links`):

```bash
kafka-cluster-links --bootstrap-server secondary-control-plane:30192 \
  --command-config etc/scenario3/secondary-client.properties \
  --create --link bidirectional-link \
  --config-file etc/scenario3/link-on-secondary.config
```

**Mirror operations** (using `confluent` CLI after certificate-based login):

```bash
confluent login --url https://localhost:30180 --certificate-only
confluent kafka mirror list --link bidirectional-link --url https://localhost:30180/kafka
```

## Certificate Paths

**Link configs** reference broker-internal paths:

- `/mnt/sslcerts/keystore.jks` (Kafka broker keystore)
- `/mnt/sslcerts/truststore.jks` (Kafka broker truststore)

**Client configs** reference local paths:

- `certs/kafka/kafka.keystore.jks` (local copy of Kafka keystore)
- `certs/global.truststore.jks` (shared truststore)

Ensure certificates are generated using `./generate_certificates.sh` before using these configuration files.
