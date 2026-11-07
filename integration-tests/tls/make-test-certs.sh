#!/bin/sh
# Regenerates the integration-test certificates and certificate revocation lists (CRLs).
# Test-only material: the keys are public and must never be trusted anywhere else.
# Run from this directory: sh make-test-certs.sh
#
#   ca.pem             CA "postgresql-native test CA" (its key is not kept)
#   server.crt/.key    server certificate for localhost and 127.0.0.1
#   client.crt/.key    client certificate CN=certuser
#   other-ca.pem       an unrelated CA
#   crl-none.pem       the CA's CRL, nothing revoked; also crls/<hash>.r0 (sslcrldir)
#   crl-revoked.pem    the CA's CRL revoking the server certificate
set -eu
days=36500
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/ca.key" -sha256 -days $days \
    -subj "/CN=postgresql-native test CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.pem
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/other.key" -sha256 -days $days \
    -subj "/CN=unrelated CA" -addext "basicConstraints=critical,CA:TRUE" -out other-ca.pem

sign() { # name subject extensions
    openssl req -new -newkey rsa:2048 -nodes -keyout "$1.key" -subj "$2" -out "$work/$1.csr"
    printf '%s\n' "$3" > "$work/$1.ext"
    openssl x509 -req -in "$work/$1.csr" -CA ca.pem -CAkey "$work/ca.key" -CAcreateserial \
        -CAserial "$work/serial" -sha256 -days $days -extfile "$work/$1.ext" -out "$1.crt"
}
sign server "/CN=localhost" "$(printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth')"
sign client "/CN=certuser" "$(printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=clientAuth')"
# containers read the server key as another user (setup-server.sh copies it)
chmod 644 server.key client.key

# A minimal "openssl ca" setup, only for the CRLs
: > "$work/index.txt"
cat > "$work/ca.cnf" <<EOF
[ca]
default_ca = test
[test]
database = $work/index.txt
default_md = sha256
default_crl_days = $days
EOF
openssl ca -config "$work/ca.cnf" -cert ca.pem -keyfile "$work/ca.key" -gencrl -out crl-none.pem
openssl ca -config "$work/ca.cnf" -cert ca.pem -keyfile "$work/ca.key" -revoke server.crt
openssl ca -config "$work/ca.cnf" -cert ca.pem -keyfile "$work/ca.key" -gencrl -out crl-revoked.pem

rm -rf crls
mkdir crls
cp crl-none.pem "crls/$(openssl crl -in crl-none.pem -hash -noout).r0"
