-- Ingest user for the ClickStack OTel collector.
--
-- RUN THIS BEFORE the first collector deploy. The collector creates the whole
-- `otel.*` schema on first write, and a collector that cannot log in does not
-- fail loudly -- it retries in a loop while every browser POST returns 200 and
-- Client Sessions stays empty, which reads exactly like "replay is not working"
-- rather than "the database said no".
--
--   ssh prabesh@62.169.19.91 'docker exec -i $(docker ps -qf name=clickhouse) \
--     clickhouse-client --multiquery' < create-ingest-user.sql
--
-- Replace the hash below first:
--   printf %s "$CH_INGEST_PASSWORD" | shasum -a 256 | awk '{print $1}'
--
-- Hash rather than plaintext deliberately: ClickHouse echoes a failing
-- statement back in its error text, so a typo in a `IDENTIFIED BY '...'` puts
-- the plaintext password into a terminal, a scrollback and possibly a log.

CREATE USER IF NOT EXISTS hyperdx_ingest
  IDENTIFIED WITH sha256_hash BY '6e9fa45ee1b14e0739e70074189edecd9b166989a4b5703725f3becf88969f0e';

-- Re-run safe: forces the password to the current value if the user exists.
ALTER USER hyperdx_ingest
  IDENTIFIED WITH sha256_hash BY '6e9fa45ee1b14e0739e70074189edecd9b166989a4b5703725f3becf88969f0e';

-- Scoped to `otel.*` and nothing else. This user must never be able to read
-- `aroundtrail.chat_texts` -- it exists only to let a publicly-reachable
-- endpoint write replay data, and the endpoint's bearer token is in the client
-- bundle, so treat the collector as reachable by anyone.
GRANT SELECT, INSERT, CREATE DATABASE, CREATE TABLE, CREATE VIEW, ALTER
  ON otel.* TO hyperdx_ingest;

-- If the collector logs ACCESS_DENIED naming `default` rather than `otel`,
-- this image is an older build whose migration version table lives in
-- `default`. Grant it and restart the container:
--
--   GRANT SELECT, INSERT, CREATE TABLE ON default.* TO hyperdx_ingest;

SHOW GRANTS FOR hyperdx_ingest;
