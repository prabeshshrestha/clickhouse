# Enabling Client Sessions (session replay)

Order matters in two places and both fail quietly if you get them wrong:
the SQL user must exist **before** the collector's first boot, and the
collector must be answering **before** nepal is built with the two build args
(a bundle that points at nothing just POSTs into a 404 on every page load).

## 1. Pick the two values

```bash
OTLP_AUTH_TOKEN=$(openssl rand -hex 32)      # ships in the client bundle. NOT a secret.
CH_INGEST_PASSWORD=$(openssl rand -hex 24)   # SQL password. IS a secret.
printf %s "$CH_INGEST_PASSWORD" | shasum -a 256 | awk '{print $1}'   # -> the hash
```

`OTLP_AUTH_TOKEN` is compiled into JavaScript anyone can read. It gates casual
noise and nothing else — never reuse a value that protects something.

## 2. Create the ingest user (BEFORE deploying the collector)

Paste the hash into `create-ingest-user.sql`, then:

```bash
scp create-ingest-user.sql prabesh@62.169.19.91:/tmp/
ssh prabesh@62.169.19.91 \
  'docker exec -i $(docker ps -qf name=clickhouse) clickhouse-client --multiquery < /tmp/create-ingest-user.sql'
```

The last statement prints the grants. If it does not name `otel.*`, stop here.

A collector that cannot log in does **not** fail loudly: it retries in a loop
while every browser POST still returns 200 and the Sessions tab stays empty —
which reads as "replay is broken" rather than "the database refused it".

## 3. Deploy the collector

In Dokploy > Environment on the ClickHouse stack, add `OTLP_AUTH_TOKEN` and
`CH_INGEST_PASSWORD` alongside the existing `CH_USER` / `CH_PASSWORD`. Push the
updated `docker-compose.yml` and redeploy the stack.

This **restarts ClickHouse too** — it is one stack. Expect a few seconds where
the Rails sink's POSTs fail; they are already fire-and-forget through a
`:discard` pool, so nothing user-facing notices.

Then wait for the certificate. Let's Encrypt issues for
`otel.62.169.19.91.sslip.io` separately from the ClickHouse one, so the first
minute or two answers with Traefik's self-signed default:

```bash
curl -sv https://otel.62.169.19.91.sslip.io/ 2>&1 | grep -i "subject:\|issuer:"
# want: issuer: ... Let's Encrypt ...   NOT "TRAEFIK DEFAULT CERT"
```

## 4. Prove ingest end to end before touching the frontend

Send one OTLP log record by hand. If this does not land, no amount of browser
debugging will help:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST https://otel.62.169.19.91.sslip.io/v1/logs \
  -H "content-type: application/json" \
  -H "authorization: $OTLP_AUTH_TOKEN" \
  --data-binary '{"resourceLogs":[{"resource":{"attributes":[
      {"key":"service.name","value":{"stringValue":"manual-probe"}}]},
    "scopeLogs":[{"logRecords":[{"timeUnixNano":"'"$(date +%s)000000000"'",
      "severityText":"INFO","body":{"stringValue":"hello from the runbook"}}]}]}]}'
```

The token goes in `authorization` with **no `Bearer ` prefix** — the ClickStack
collector configures bearer auth with an empty scheme.

Then confirm the schema created itself and the row arrived:

```bash
curl -sS --user "$CH_USER:$CH_PASSWORD" --data-binary \
  "SELECT name FROM system.tables WHERE database='otel' ORDER BY name FORMAT PrettyCompact" \
  https://62.169.19.91.sslip.io/
curl -sS --user "$CH_USER:$CH_PASSWORD" --data-binary \
  "SELECT count() FROM otel.otel_logs WHERE ServiceName='manual-probe'" \
  https://62.169.19.91.sslip.io/
```

`otel` not existing at all means step 2 was skipped or the grant is wrong —
check `docker logs` on the collector for `ACCESS_DENIED`.

## 5. Build nepal with replay on

Add to the nepal Dokploy service's build args (**build args, not runtime env** —
they are baked by `next build`):

```
NEXT_PUBLIC_HYPERDX_URL=https://otel.62.169.19.91.sslip.io
NEXT_PUBLIC_HYPERDX_API_KEY=<OTLP_AUTH_TOKEN>
```

**Set these on the nepal service ONLY.** `frontend-tibet` is the same tree and
the same Dockerfile built with another slug on this host, and it got its other
five `NEXT_PUBLIC_*` values by copying nepal's. Check tibet's build args do not
carry these two, or tibet silently starts recording replay as well — and
`sessionReplayConfig` will happily name it `frontend-tibet` and file the
sessions, so nothing looks wrong.

Redeploy nepal. Then load `https://www.aroundtrail.com`, click through three or
four pages, and check:

```bash
curl -sS --user "$CH_USER:$CH_PASSWORD" --data-binary \
  "SELECT count() FROM otel.hyperdx_sessions" https://62.169.19.91.sslip.io/
```

Zero here with a non-zero `otel_logs` means the rrweb routing connector is not
matching — that is the difference between the ClickStack image and the upstream
contrib one, so check the image tag first.

## 6. Verify the masking, in a browser, before leaving it on

**Do this, do not assume it.** Open a replay in HyperDX > Client Sessions and
watch a sign-in: the password and email fields must render as blocked boxes.
`maskAllInputs` is the one rrweb default that is wrong for us, and a config
that silently failed to apply looks identical to one that worked until you
watch the replay of a form.

### If the probe in step 4 returned 404 rather than 200

That is a path problem, not an auth one — check the collector's actual OTLP
HTTP route before touching the token. Likewise, if step 4's table listing shows
a log table under a name other than `otel_logs`, use the name it printed: that
query is the source of truth, the one after it is an assumption.

## Rolling back

Remove the two build args and redeploy nepal — that stops every browser from
sending, immediately and without touching the server. The collector keeps
running harmlessly; drop the service from the compose file at leisure.

## Retention

`ttl: 720h` (30 days) is the ClickStack collector's default and it applies to
`otel.hyperdx_sessions` too. That is now a published-promise-shaped number and
the privacy page has to agree with it before this goes live for real.
