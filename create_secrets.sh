#!/bin/bash

# Exit on any error, print all commands
set -o nounset \
    -o errexit

echo "Creating TLS and MDS secrets for both primary and secondary clusters..."
echo ""

# Create secrets in both clusters
for cluster in primary secondary
do
  echo "--------------------------------------------------------------------"
  echo "Creating secrets in kind-${cluster} cluster..."
  echo "--------------------------------------------------------------------"

  # Set the context for this cluster
  CONTEXT="kind-${cluster}"

  # Ensure the confluent namespace exists
  kubectl create namespace confluent --context $CONTEXT --dry-run=client -o yaml | kubectl apply --context $CONTEXT -f -

  # Create JKS-based secrets (for Java components)
  for i in kraftcontroller kafka connect schemaregistry krp controlcenter-ng
  do
    echo "  Creating secret: $i-tls"
    kubectl create secret generic $i-tls \
      --from-file=keystore.jks=./certs/$i/$i.keystore.jks \
      --from-file=truststore.jks=./certs/$i/$i.truststore.jks \
      --from-file=jksPassword.txt=./certs/$i/$i.jksPassword.txt \
      --namespace confluent \
      --context $CONTEXT \
      --dry-run=client -o yaml | kubectl apply --context $CONTEXT -f -
  done

  # Create PEM-based secrets (for C3++ components)
  for i in prometheus-client alertmanager-client prometheus alertmanager connector cluster-link rest-class
  do
    echo "  Creating secret: $i-tls"
    kubectl create secret generic $i-tls \
      --from-file=fullchain.pem=./certs/$i/$i.pem \
      --from-file=cacerts.pem=./certs/$i/ca.pem  \
      --from-file=privkey.pem=./certs/$i/key.pem  \
      --namespace confluent \
      --context $CONTEXT \
      --dry-run=client -o yaml | kubectl apply --context $CONTEXT -f -
  done

  # Create password encoder secret for Schema Registries
  kubectl create secret generic password-encoder-secret \
      --from-file=password-encoder.txt=./infra/password-encoder-secret.txt \
      --namespace confluent \
      --context $CONTEXT \
      --dry-run=client -o yaml | kubectl apply --context $CONTEXT -f -

  # --- MDS Token Key Pair ---
  echo "  Creating secret: mds-token-keypair"
  kubectl create secret generic mds-token-keypair \
    --from-file=mdsTokenKeyPair.pem=./certs/mds/mds-tokenkeypair.pem \
    --from-file=mdsPublicKey.pem=./certs/mds/mds-publickey.pem \
    --namespace confluent \
    --context $CONTEXT \
    --dry-run=client -o yaml | kubectl apply --context $CONTEXT -f -

  # --- File-based MDS Users ---
  # MDS authenticates bearer token users against this file (used by KafkaRestClass).
  echo "  Creating secret: mds-file-users"
  kubectl create secret generic mds-file-users \
    --from-literal=userstore.txt="admin:admin-secret
kafka:kafka-secret
clusterlink:link-secret" \
    --namespace confluent \
    --context $CONTEXT \
    --dry-run=client -o yaml | kubectl apply --context $CONTEXT -f -

  # --- Bearer credentials for Kafka REST (internal dependency + KafkaRestClass) ---
  echo "  Creating secret: kafka-credential"
  kubectl create secret generic kafka-credential \
    --from-literal=bearer.txt="username=kafka
password=kafka-secret" \
    --namespace confluent \
    --context $CONTEXT \
    --dry-run=client -o yaml | kubectl apply --context $CONTEXT -f -


kubectl create secret generic c3-basic-auth \
  --from-literal=basic.txt="admin:admin-secret" \
  --namespace confluent \
  --context $CONTEXT \
  --dry-run=client -o yaml | kubectl apply --context $CONTEXT -f -

  # --- Bearer credentials for cluster link REST operations ---
  echo "  Creating secret: clusterlink-credential"
  kubectl create secret generic clusterlink-credential \
    --from-literal=bearer.txt="username=clusterlink
password=link-secret" \
    --namespace confluent \
    --context $CONTEXT \
    --dry-run=client -o yaml | kubectl apply --context $CONTEXT -f -

  echo ""
  echo "All secrets created in kind-${cluster} cluster"
  echo ""
done

echo "TLS and MDS secrets created successfully in both clusters!"
