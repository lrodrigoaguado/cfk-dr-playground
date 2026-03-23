#!/bin/bash
# scripts/teardown.sh
# Complete environment cleanup

set -e

echo "🧹 Starting full environment cleanup..."
echo ""

# Kill background port-forward processes
echo "Stopping port-forward processes..."
pkill -f "port-forward svc/controlcenter-ng" 2>/dev/null || echo "  No port-forward processes found"

# Delete Kind clusters
echo ""
echo "Deleting Kind clusters..."
kind delete cluster --name primary 2>/dev/null || echo "  Primary cluster not found"
kind delete cluster --name secondary 2>/dev/null || echo "  Secondary cluster not found"

# Remove Docker network
echo ""
echo "Removing Docker network..."
docker network rm kind-shared 2>/dev/null || echo "  Network not found"

# Clean generated certificates
echo ""
echo "Removing generated certificates..."
if [ -d "certs" ]; then
  rm -rf certs/*.pem certs/*.pem.attr
  rm -rf certs/*/
  echo "  ✓ Certificates removed"
else
  echo "  No certificates directory found"
fi

# Unset environment variables
echo ""
echo "Unsetting environment variables..."
unset CONFLUENT_PLATFORM_CERTIFICATE_AUTHORITY_PATH
unset CONFLUENT_PLATFORM_CLIENT_CERT_PATH
unset CONFLUENT_PLATFORM_CLIENT_KEY_PATH
unset PRIMARY_CLUSTER_ID
unset SECONDARY_CLUSTER_ID
unset KAFKA_LOG4J_OPTS
echo "  ✓ Environment variables unset"

echo ""
echo "✅ Cleanup complete!"
echo ""
echo "Note: You may need to manually remove /etc/hosts entries:"
echo "  127.0.0.1 primary-control-plane secondary-control-plane controlcenter-ng.confluent.svc.cluster.local"
