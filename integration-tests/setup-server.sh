#!/bin/sh
# Prepares a PostgreSQL container (the official image) for the integration tests:
# TLS with the test certificates in integration-tests/tls, a user for each
# authentication method, and pg_hba.conf rules for them. Then set POSTGRES_SETUP=1.
#
#   sh integration-tests/setup-server.sh <container> [superuser]
#
# Users (all in database testdb): scramuser, md5user, clearuser (passwords "<name>_pw"),
# trustuser (no password), tlsuser (TLS only), certuser (client certificate only),
# saslpuser (a password that SASLprep changes).
set -e
container=$1
superuser=${2:-testuser}
dir=$(dirname "$0")/tls

docker exec -u root "$container" mkdir -p /etc/pgtls
for f in ca.pem server.crt server.key; do
    docker cp "$dir/$f" "$container:/etc/pgtls/$f"
done
docker exec -u root "$container" sh -c 'chown -R postgres:postgres /etc/pgtls && chmod 600 /etc/pgtls/server.key'

psql() {
    docker exec -i "$container" psql -v ON_ERROR_STOP=1 -q -U "$superuser" -d testdb "$@"
}

hba=$(psql -At -c "SHOW hba_file")
psql <<'SQL'
SET client_min_messages = warning;
ALTER SYSTEM SET ssl = on;
ALTER SYSTEM SET ssl_cert_file = '/etc/pgtls/server.crt';
ALTER SYSTEM SET ssl_key_file = '/etc/pgtls/server.key';
ALTER SYSTEM SET ssl_ca_file = '/etc/pgtls/ca.pem';
SET password_encryption = 'scram-sha-256';
DROP ROLE IF EXISTS scramuser, md5user, clearuser, trustuser, tlsuser, certuser, saslpuser;
CREATE ROLE scramuser LOGIN PASSWORD 'scramuser_pw';
CREATE ROLE clearuser LOGIN PASSWORD 'clearuser_pw';
CREATE ROLE trustuser LOGIN;
CREATE ROLE tlsuser LOGIN PASSWORD 'tlsuser_pw';
CREATE ROLE certuser LOGIN;
CREATE ROLE saslpuser LOGIN PASSWORD E'I­X pass';
SET password_encryption = 'md5';
CREATE ROLE md5user LOGIN PASSWORD 'md5user_pw';
GRANT ALL ON DATABASE testdb TO scramuser, md5user, clearuser, trustuser, tlsuser, certuser, saslpuser;
SQL

docker exec -i -u root "$container" sh -c "cat > '$hba' && chown postgres:postgres '$hba'" <<'HBA'
local     all  all        trust
host      all  trustuser  all  trust
host      all  clearuser  all  password
host      all  md5user    all  md5
host      all  scramuser  all  scram-sha-256
host      all  saslpuser  all  scram-sha-256
hostnossl all  tlsuser    all  reject
hostssl   all  tlsuser    all  scram-sha-256
hostssl   all  certuser   all  cert
host      all  all        all  md5
HBA
psql -c "SELECT pg_reload_conf()" > /dev/null
sleep 1
echo "ssl: $(psql -At -c 'SHOW ssl')"
