-- AroundTrail site events -> ClickHouse
-- Written 2026-09-05. Shape taken from the EXISTING Rails pipe:
--   backend-service/app/services/telemetry.rb        (Telemetry.record)
--   app/controllers/api/v1/base_controller.rb:142    ("browse.depth")
--   app/controllers/api/v1/search_controller.rb:8    ("search.miss")
--
-- The write path already exists and does not need rebuilding. Telemetry.record
-- is a bounded thread pool (MAX_THREADS=4, MAX_QUEUE=200) with
-- fallback_policy: :discard, deliberately chosen over Active Job because the
-- Solid Queue tables live in the PRIMARY database and enqueuing would mean two
-- INSERTs into Postgres on a read-only crawler-reachable path. That reasoning
-- holds for ClickHouse too. Add a ClickHouse sink INSIDE Telemetry.post;
-- do not build a second pipe.
--
-- ANONYMOUS BY CONSTRUCTION -- KEEP IT THAT WAY.
-- Telemetry.record's signature is (name, country_slug:, metadata:). It carries
-- no user id, no session id, no IP. That is what keeps this table out of the
-- DSAR path entirely (unlike chat_texts, see schema-chat-telemetry.sql).
-- Adding a user_id column here would drag site events into `make dsar-export`
-- and `make dsar-erase`. Don't.

CREATE DATABASE IF NOT EXISTS aroundtrail;

CREATE TABLE IF NOT EXISTS aroundtrail.site_events
(
    event_time    DateTime64(3)                CODEC(Delta, ZSTD(1)),
    event_date    Date MATERIALIZED toDate(event_time),

    name          LowCardinality(String),      -- browse.depth | search.miss | ...
    country_slug  LowCardinality(String),

    -- Typed columns for the metadata keys that recur today. Per
    -- schema-json-when-to-use: typed columns for known keys, the Map below for
    -- the rest. Per schema-types-avoid-nullable: DEFAULT '' / 0, never Nullable.
    vertical      LowCardinality(String) DEFAULT '',   -- browse.depth
    page          UInt16                 DEFAULT 0,    -- browse.depth
    query         String                 DEFAULT '',   -- search.miss
    query_length  UInt16                 DEFAULT 0,    -- search.miss

    -- Everything else, without an ALTER per new event type. A new
    -- Telemetry.record call site works on day one; promote a key to a typed
    -- column once you actually query it.
    metadata      Map(LowCardinality(String), String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
-- IMMUTABLE (schema-pk-plan-before-creation).
-- Low-to-high cardinality, time last (schema-pk-cardinality-order):
--   country_slug ~7 values, name ~2-10, event_time high.
-- Every real question is "for country X, event Y, over window Z".
-- A query that omits country_slug scans everything (schema-pk-filter-on-orderby).
ORDER BY (country_slug, name, event_time)
TTL event_date + INTERVAL 12 MONTH DELETE
SETTINGS index_granularity = 8192;


-- ---------------------------------------------------------------------------
-- INSERT SETTINGS -- this is the part that matters for this pipe.
-- ---------------------------------------------------------------------------
-- Telemetry.record fires ONE event per request. Per insert-batch-size, single-row
-- INSERTs are the classic ClickHouse anti-pattern: each one creates a part, and
-- parts accumulate until merges cannot keep up ("too many parts").
--
-- Per insert-async-small-batches, the fix is server-side batching rather than
-- restructuring the Rails pipe. Send every INSERT with:
--
--   async_insert=1
--   wait_for_async_insert=0     -- fire-and-forget, matches Telemetry's contract
--
-- ClickHouse then buffers rows in memory and flushes a real batch on
-- async_insert_busy_timeout_ms (default 1s) or async_insert_max_data_size.
-- wait_for_async_insert=0 means the HTTP call returns before the flush, so a
-- ClickHouse hiccup cannot add latency to a traveller's page load -- which is the
-- whole point of the :discard pool.
--
-- As a URL, which is how Telemetry.post would send it:
--   POST https://<host>/?async_insert=1&wait_for_async_insert=0
--        &query=INSERT%20INTO%20aroundtrail.site_events%20FORMAT%20JSONEachRow
--
-- Trade-off to know: with wait_for_async_insert=0 an accepted HTTP 200 does NOT
-- mean the row is durable. That is the correct trade for best-effort analytics
-- that already drops events under load by design, and the wrong one for anything
-- billable.


-- ---------------------------------------------------------------------------
-- What this buys, concretely
-- ---------------------------------------------------------------------------
-- Root CLAUDE.md, on Tibet's "Popular searches": six terms were chosen by
-- reasoning and ALL SIX returned total:0, which reads to a visitor as "this site
-- has no content". The lesson recorded there is "Never pick these terms by
-- reasoning -- measure them."
--
-- search.miss is exactly that measurement, and today it goes to Langfuse, where
-- it is an event stream rather than something you can GROUP BY. Here:
--
--   SELECT query, count() AS n
--   FROM aroundtrail.site_events
--   WHERE country_slug = 'tibet' AND name = 'search.miss'
--     AND event_date >= today() - 90
--   GROUP BY query ORDER BY n DESC LIMIT 50;
--
-- Note the WHERE leads with country_slug and name -- the ORDER BY prefix.
--
-- browse.depth answers the other one: which verticals do people page past 1 on,
-- per country. That is a content-expansion signal the editorial plans currently
-- guess at.


-- ---------------------------------------------------------------------------
-- OPEN ITEM -- the privacy page contradicts current collection ALREADY.
-- ---------------------------------------------------------------------------
-- frontend-nepal/src/app/privacy/page.tsx today says, verbatim:
--   "privacy-friendly, cookie-free analytics (Vercel Web Analytics)"
--   "AroundTrail is hosted on Vercel"
--   "AroundTrail does not set any tracking cookies."
--   "No other third-party tracking or advertising services are used."
--
-- All four are false for nepal as shipped:
--   - nepal is deployed on Dokploy, not Vercel (root CLAUDE.md, Production
--     Deployment table). Vercel Web Analytics is mounted in bhutan's and
--     germany's layout.tsx -- not nepal's.
--   - PostHog IS live on nepal: frontend-nepal/instrumentation-client.ts calls
--     posthog.init with a production token, and there are ~12 capture() sites.
--   - PostHog sets cookies by default.
--   - packages/account-ui/src/components/session-provider.tsx calls
--     posthog.identify(user.id) -- individual, logged-in user tracking.
--   - posthog-self-driving-report.md records Session Replay as ENABLED.
--
-- 12 MONTH above is therefore a placeholder, not a decision. Fix the page
-- first; the retention window is a promise, and this file should match whatever
-- the page ends up saying. This is a pre-existing problem that ClickHouse did
-- not create -- but adding a third analytics store to a site whose privacy page
-- understates the first two makes it worse, not neutral.
