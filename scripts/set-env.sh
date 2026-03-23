#!/bin/bash
# scripts/set-env.sh
# Source this file to set all required environment variables
# Usage: source scripts/set-env.sh

# TLS certificate paths for confluent CLI
export CONFLUENT_PLATFORM_CERTIFICATE_AUTHORITY_PATH=./certs/cacert.pem
export CONFLUENT_PLATFORM_CLIENT_CERT_PATH=./certs/cli-admin/cli-admin-signed.crt
export CONFLUENT_PLATFORM_CLIENT_KEY_PATH=./certs/cli-admin/cli-admin-key.pem

# Cluster IDs (for Scenario 3)
export PRIMARY_CLUSTER_ID="primaryCluster-1234567"
export SECONDARY_CLUSTER_ID="secondaryCluster-12345"

# Suppress Kafka CLI warnings (for Scenario 3)
export KAFKA_LOG4J_OPTS="-Dlog4j.configuration=file:etc/scenario3/tools-log4j.properties"

echo "✅ Environment variables set:"
echo "  CONFLUENT_PLATFORM_CERTIFICATE_AUTHORITY_PATH=$CONFLUENT_PLATFORM_CERTIFICATE_AUTHORITY_PATH"
echo "  CONFLUENT_PLATFORM_CLIENT_CERT_PATH=$CONFLUENT_PLATFORM_CLIENT_CERT_PATH"
echo "  CONFLUENT_PLATFORM_CLIENT_KEY_PATH=$CONFLUENT_PLATFORM_CLIENT_KEY_PATH"
echo "  PRIMARY_CLUSTER_ID=$PRIMARY_CLUSTER_ID"
echo "  SECONDARY_CLUSTER_ID=$SECONDARY_CLUSTER_ID"
echo "  KAFKA_LOG4J_OPTS=$KAFKA_LOG4J_OPTS"
