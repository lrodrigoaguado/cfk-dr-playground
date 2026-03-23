#!/bin/bash

# Exit on any error, print all commands
set -o nounset \
    -o errexit

# --- 1. CA Setup ---
# Ensure the "certs" directory exists
if [ ! -d "certs" ]; then
  mkdir -p certs/ca
fi
# Clean up previous files and set up CA directory structure
cd certs
rm -rf *.pem *.pem.attr
rm -rf ca/serial* ca/index* ca/certsdb*
rm -f global.truststore.jks
touch ca/serial
echo 1000 > ca/serial
touch ca/index

# Generate the Certificate Authority (CA) key and self-signed certificate
# This creates cacert.pem (the public cert) and cakey.pem (the private key)
openssl req -new -x509 \
    -config ca/openssl-ca.cnf \
    -keyout cakey.pem \
    -out cacert.pem \
    -newkey rsa:4096 \
    -sha256 \
    -nodes \
    -subj '/CN=ca1.test.confluent.io/OU=TEST/O=CONFLUENT/L=PaloAlto/ST=Ca/C=US' \
    -passin pass:confluent

echo "✅ CA certificate and key generated."

# Create truststore and import the CA cert
keytool -noprompt -importcert \
        -keystore global.truststore.jks \
        -alias CARoot \
        -file cacert.pem \
        -storepass confluent \
        -storetype PKCS12

# --- 2. Component Certificate Generation ---
# Loop through each component to generate its keystore and truststore
for i in kraftcontroller kafka connect schemaregistry krp controlcenter-ng cli-admin
do
  echo ""
  echo "------------------------------- $i -------------------------------"
  rm -rf $i
  mkdir -p $i

  # Determine SAN based on component
  if [ "$i" == "kafka" ]; then
    # Kafka needs extensive SANs for cross-cluster communication
    # primary-control-plane / secondary-control-plane are the Kind node hostnames used for NodePort access
    SAN="DNS:$i,DNS:$i.confluent,DNS:$i.confluent.svc.cluster.local,DNS:*.$i.confluent.svc.cluster.local,DNS:kafka-0.kafka.confluent.svc.cluster.local,DNS:kafka-1.kafka.confluent.svc.cluster.local,DNS:kafka-2.kafka.confluent.svc.cluster.local,DNS:localhost,DNS:*.confluent.svc.cluster.local,DNS:primary-control-plane,DNS:secondary-control-plane"
  elif [ "$i" == "kraftcontroller" ]; then
    SAN="DNS:$i,DNS:$i.confluent,DNS:$i.confluent.svc.cluster.local,DNS:*.$i.confluent.svc.cluster.local,DNS:kraftcontroller-0.kraftcontroller.confluent.svc.cluster.local,DNS:kraftcontroller-1.kraftcontroller.confluent.svc.cluster.local,DNS:kraftcontroller-2.kraftcontroller.confluent.svc.cluster.local,DNS:localhost,DNS:*.confluent.svc.cluster.local"
  else
    # Other components use standard SANs
    SAN="DNS:$i,DNS:$i.confluent.svc.cluster.local,DNS:*.$i.confluent.svc.cluster.local,DNS:*.confluent.svc.cluster.local,DNS:$i-service"
  fi

  # Create host keystore
  keytool -genkey -noprompt \
  	  -alias $i \
  	  -dname "CN=$i,OU=TEST,O=CONFLUENT,L=PaloAlto,S=Ca,C=US" \
          -ext san=$SAN \
  	  -keystore $i/$i.keystore.jks \
  	  -keyalg RSA \
  	  -storepass confluent \
  	  -keypass confluent \
  	  -validity 999 \
  	  -storetype pkcs12

  # Create the certificate signing request (CSR)
  keytool -certreq \
          -keystore $i/$i.keystore.jks \
          -alias $i \
          -storepass confluent \
          -keypass confluent \
          -storetype pkcs12 \
          -ext san=$SAN \
          -file $i/$i.csr

  # Sign the host certificate with the certificate authority (CA)
  openssl ca \
          -config ca/openssl-ca.cnf \
          -policy signing_policy \
          -extensions signing_req \
          -passin pass:confluent \
          -batch \
          -out $i/$i-signed.crt \
          -in $i/$i.csr

  # Import the CA cert into the keystore
  keytool -noprompt -importcert \
          -alias CARoot \
          -file cacert.pem \
          -keystore $i/$i.keystore.jks \
          -storepass confluent \
          -storetype PKCS12

  # Import the signed host certificate, associating it with the existing private key alias
  keytool -noprompt -importcert \
          -keystore $i/$i.keystore.jks \
          -alias $i \
          -file $i/$i-signed.crt \
          -storepass confluent \
          -storetype PKCS12

  # Import the cert in the truststore
  keytool -importcert -noprompt \
    -alias $i \
    -file $i/$i-signed.crt \
    -keystore global.truststore.jks \
    -storepass confluent \
    -storetype PKCS12

  # Save creds
  echo -n "jksPassword=confluent" > $i/${i}.jksPassword.txt

  # Copy the CA certificate to the component's directory for easy access
  cp cacert.pem $i/ca.pem

  # Clean up the intermediate CSR file
  rm $i/$i.csr

  echo ""
  echo "✅ KeyStore and TrustStore certificates generated for $i in directory: $i/"
done


# --- 3. Additional PEM Certificate Generation ---
# For some reason, I could not make C3++ work with keystore/truststore, but needed pem certs
for i in prometheus-client alertmanager-client prometheus alertmanager connector cluster-link rest-class
do
  echo "------------------------------- $i -------------------------------"
  #rm -rf $i
  mkdir -p $i

  # Generate the private key
  openssl genrsa -out $i/key.pem 4096

  # Create the Certificate Signing Request (CSR)
  # The SAN (Subject Alternative Name) is crucial for proper hostname validation
  openssl req -new \
          -key $i/key.pem \
          -subj "/CN=$i,OU=TEST,O=CONFLUENT,L=PaloAlto,S=Ca,C=US" \
          -addext "subjectAltName=DNS:$i,DNS:$i.confluent.svc.cluster.local,DNS:*.$i.confluent.svc.cluster.local,DNS:*.confluent.svc.cluster.local" \
          -out $i/$i.csr

  # Sign the CSR with our CA
  # This creates the final, signed public certificate for the component
  openssl ca \
          -config ca/openssl-ca.cnf \
          -policy signing_policy \
          -extensions signing_req \
          -passin pass:confluent \
          -batch \
          -out $i/$i.pem \
          -in $i/$i.csr

  keytool -importcert -noprompt \
    -alias $i-pem \
    -file $i/$i.pem \
    -keystore global.truststore.jks \
    -storepass confluent \
    -storetype PKCS12

  # Copy the CA certificate to the component's directory for easy access
  cp cacert.pem $i/ca.pem

  # Clean up the intermediate CSR file
  rm $i/$i.csr

  echo ""
  echo "✅ PEM certificates generated for $i in directory: $i/"
done

# Copy global truststore to all component directories
for i in kraftcontroller kafka connect schemaregistry rest-class cli-admin prometheus-client alertmanager-client prometheus alertmanager controlcenter-ng krp connector cluster-link
do
  cp global.truststore.jks ./$i/$i.truststore.jks
done

rm 1*.pem

# --- 3.5 CLI Certificate Export ---
# Extract the kafka private key to PEM for confluent CLI certificate-based authentication
echo ""
echo "------------------------------- CLI Certificate Export -------------------------------"
openssl pkcs12 -in cli-admin/cli-admin.keystore.jks -nocerts -nodes \
  -out cli-admin/cli-admin-key.pem -passin pass:confluent
echo "✅ cli-admin private key exported to PEM for CLI use: cli-admin/cli-admin-key.pem"

# --- 4. MDS Token Key Pair Generation ---
echo ""
echo "------------------------------- MDS Token Key Pair -------------------------------"
mkdir -p mds

# Generate RSA key pair for MDS token signing
openssl genrsa -out mds/mds-tokenkeypair.pem 2048

# Extract the public key
openssl rsa -in mds/mds-tokenkeypair.pem -outform PEM -pubout -out mds/mds-publickey.pem

echo ""
echo "✅ MDS token key pair generated in directory: mds/"

echo ""
echo "🎉🎉 All certificates and MDS keys have been generated successfully."
