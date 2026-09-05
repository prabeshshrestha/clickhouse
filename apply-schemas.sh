#!/usr/bin/env bash
#
# Apply the AroundTrail ClickHouse schemas. Idempotent -- every statement is
# CREATE ... IF NOT EXISTS or ADD INDEX IF NOT EXISTS, so re-running is a no-op.
#
#   CH_PASSWORD=... ./apply-schemas.sh              # dry run, prints statements
#   CH_PASSWORD=... ./apply-schemas.sh --apply      # actually runs them
#
# Env:
#   CH_URL       default https://62.169.19.91.sslip.io
#   CH_USER      default superuser
#   CH_PASSWORD  required
#
# Runs over the HTTPS interface, so it works from a laptop with no SSH and no
# docker access. See the bottom of this file for the docker exec alternative.

set -euo pipefail

CH_URL="${CH_URL:-https://62.169.19.91.sslip.io}"
CH_USER="${CH_USER:-superuser}"
CH_PASSWORD="${CH_PASSWORD:-}"
APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES=("$HERE/schema-site-events.sql" "$HERE/schema-chat-telemetry.sql")

if [[ -z "$CH_PASSWORD" ]]; then
  echo "CH_PASSWORD is not set." >&2
  exit 1
fi

# --- preflight -------------------------------------------------------------
# Do NOT skip this. If TLS is not yet issued the cert is "TRAEFIK DEFAULT CERT"
# and curl fails here rather than half-applying a schema over a bad channel.
echo "==> preflight: $CH_URL"
got="$(curl -sS --fail-with-body --max-time 15 \
        --user "$CH_USER:$CH_PASSWORD" \
        --data-urlencode 'query=SELECT 1' \
        "$CH_URL/" 2>&1)" || { echo "preflight FAILED: $got" >&2; exit 1; }
[[ "$got" == "1" ]] || { echo "preflight returned unexpected: $got" >&2; exit 1; }
echo "    ok (valid cert, auth accepted)"

# --- split SQL into statements ---------------------------------------------
# Comments are stripped FIRST: these files contain example queries inside `--`
# comments that end in a semicolon, and a naive split on ';' would emit them as
# statements. ClickHouse's HTTP interface runs one query per request.
split_statements() {
  python3 - "$1" <<'PY'
import re, sys
raw = open(sys.argv[1]).read()
no_comments = "\n".join(re.sub(r'--.*$', '', line) for line in raw.splitlines())
for stmt in no_comments.split(';'):
    s = stmt.strip()
    if s:
        print(s.replace('\n', ' ') if False else s)
        print('\x00')          # NUL separator: safe, cannot occur in the SQL
PY
}

run_statement() {
  local stmt="$1"
  local label
  label="$(echo "$stmt" | tr '\n' ' ' | cut -c1-72)"
  if [[ $APPLY -eq 0 ]]; then
    echo "    [dry-run] $label ..."
    return
  fi
  echo "    $label ..."
  curl -sS --fail-with-body --max-time 30 \
    --user "$CH_USER:$CH_PASSWORD" \
    --data-binary "$stmt" \
    "$CH_URL/" > /dev/null
}

for f in "${FILES[@]}"; do
  echo "==> $(basename "$f")"
  while IFS= read -r -d $'\x00' stmt; do
    [[ -z "${stmt//[$'\n\t ']/}" ]] && continue
    run_statement "$stmt"
  done < <(split_statements "$f")
done

if [[ $APPLY -eq 0 ]]; then
  echo
  echo "Dry run only. Re-run with --apply to execute."
  exit 0
fi

# --- verify ----------------------------------------------------------------
# A CREATE that silently did nothing and a CREATE that worked look identical
# from the exit code, so check the TTLs actually attached -- chat_texts having
# no TTL is the failure that matters, because it is the privacy commitment.
echo
echo "==> verify"
curl -sS --user "$CH_USER:$CH_PASSWORD" --data-urlencode "query=
  SELECT name, sorting_key, if(empty(engine_full), '?', 'ok') AS created
  FROM system.tables WHERE database = 'aroundtrail' ORDER BY name FORMAT PrettyCompact
" "$CH_URL/"

echo
echo "==> TTLs (chat_texts MUST show 90 DAY)"
curl -sS --user "$CH_USER:$CH_PASSWORD" --data-urlencode "query=
  SELECT table, extract(engine_full, 'TTL[^S]*') AS ttl
  FROM system.tables WHERE database = 'aroundtrail' ORDER BY table FORMAT PrettyCompact
" "$CH_URL/"

# ---------------------------------------------------------------------------
# ALTERNATIVE: straight from the Dokploy host, no TLS needed.
#
#   scp schema-*.sql prabesh@62.169.19.91:/tmp/
#   ssh prabesh@62.169.19.91 '
#     C=$(docker ps -qf name=clickhouse)
#     for f in /tmp/schema-*.sql; do
#       docker exec -i $C clickhouse-client --multiquery < "$f"
#     done'
#
# clickhouse-client --multiquery parses comments and statement boundaries
# itself, so it needs no splitting. Useful if the cert is not up yet -- but note
# it does NOT verify the channel the app will actually use.
# ---------------------------------------------------------------------------
