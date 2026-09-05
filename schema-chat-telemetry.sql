-- AroundTrail chat telemetry -> ClickHouse
-- Written 2026-09-05. Source of truth for the shape: agent-service's
-- lib/graph/finalize.py (TurnContext, trace_dimensions, trace_scores).
--
-- TWO TABLES ON PURPOSE. They hold the same turn but have different
-- retention obligations, and a single MergeTree cannot give two TTLs to two
-- column groups without column-level TTL that quietly rots the guarantee:
--
--   chat_turns  -- dimensions + scores, NO user text.        TTL 24 months
--   chat_texts  -- prompt + completion, traveller-written.   TTL 90 days
--
-- 90 days is not a preference. Root CLAUDE.md: chat `conversations` are swept
-- at RETENTION_CONVERSATION_DAYS=90, and frontend-nepal/src/app/privacy/page.tsx
-- PUBLISHES that window to the people who typed the text. A ClickHouse copy
-- outliving it makes the privacy page false.

CREATE DATABASE IF NOT EXISTS aroundtrail;

-- ---------------------------------------------------------------------------
-- chat_turns -- one row per finished turn, every exit path.
-- ---------------------------------------------------------------------------
-- Column names mirror trace_dimensions()/trace_scores() VERBATIM so a Langfuse
-- trace and a ClickHouse row for the same turn are comparable with no mapping
-- table. Do not "tidy" these names.
CREATE TABLE IF NOT EXISTS aroundtrail.chat_turns
(
    event_time          DateTime64(3)                     CODEC(Delta, ZSTD(1)),
    event_date          Date MATERIALIZED toDate(event_time),

    -- Identity. trace_id joins a row to its Langfuse trace; conversation_id
    -- joins to the Agent DB `conversations` row.
    conversation_id     String,
    request_id          String,
    trace_id            String  DEFAULT '',

    -- Dimensions, from trace_dimensions().
    country_slug        LowCardinality(String),
    intent              LowCardinality(String),           -- info | plan | ...
    source              LowCardinality(String),           -- chat | plan
    trip_subtype        LowCardinality(String) DEFAULT '',
    grounding_outcome   LowCardinality(String),           -- pass|dropped|no_evidence|clarify|error

    -- BOTH tool counters. finalize.py is explicit that these differ: tool_calls
    -- counts only what the MODEL chose (excludes the deterministic
    -- enrich_plan_context round), so it reads 2-3 on a plan turn where 8 tools
    -- ran. It is the honest "did the agent retrieve enough?" metric.
    -- tool_messages_total is the true count. Collapsing them loses that.
    tool_calls          UInt16  DEFAULT 0,
    tool_messages_total UInt16  DEFAULT 0,

    -- Scores, from trace_scores(). UInt8 0/1 rather than Nullable: a clarify
    -- turn genuinely has no grounding_pass, so scores_applied says which of the
    -- conditional ones were computed (per schema-types-avoid-nullable).
    answer_delivered    UInt8   DEFAULT 0,
    grounding_pass      UInt8   DEFAULT 0,
    has_links           UInt8   DEFAULT 0,
    scores_applied      UInt8   DEFAULT 0,                -- 1 = grounding_pass/has_links are real

    -- Link-or-drop accounting (DeletionStats). filter_ran distinguishes
    -- "filter ran and deleted nothing" (0%) from "filter never ran" -- which
    -- finalize.py treats as different states, and a bare 0 would conflate.
    filter_ran          UInt8   DEFAULT 0,
    deleted_pct         UInt8   DEFAULT 0,
    dropped_sentences   UInt16  DEFAULT 0,
    answer_len          UInt32  DEFAULT 0,

    latency_ms          UInt32  DEFAULT 0,
    error               String  DEFAULT ''                -- truncated, as in finalize.py
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
-- ORDER BY is IMMUTABLE (schema-pk-plan-before-creation) -- this is the one
-- decision that cannot be walked back.
--
-- Low-to-high cardinality with time last (schema-pk-cardinality-order):
--   country_slug   ~6 values
--   intent         ~4
--   grounding_outcome ~5
--   event_time     high
--
-- Chosen because every real question filters country -> intent -> outcome ->
-- window, e.g. "grounding pass rate for nepal plan turns last week". Queries
-- MUST include country_slug to get index pruning (schema-pk-filter-on-orderby);
-- a query filtering only on intent scans everything.
ORDER BY (country_slug, intent, grounding_outcome, event_time)
TTL event_date + INTERVAL 24 MONTH DELETE
SETTINGS index_granularity = 8192;

-- Trace/conversation lookups skip the ORDER BY prefix entirely, so they need a
-- skipping index (query-index-skipping-indices) or they full-scan.
ALTER TABLE aroundtrail.chat_turns
    ADD INDEX IF NOT EXISTS idx_conversation conversation_id TYPE bloom_filter(0.01) GRANULARITY 4;
ALTER TABLE aroundtrail.chat_turns
    ADD INDEX IF NOT EXISTS idx_trace trace_id TYPE bloom_filter(0.01) GRANULARITY 4;

-- ---------------------------------------------------------------------------
-- chat_texts -- traveller-written text. 90-DAY TTL, matching the privacy page.
-- ---------------------------------------------------------------------------
-- Separate table so the 90-day window is a table-level guarantee you can read
-- off the DDL, not a per-column footnote. DSAR (`make dsar-erase`) spans Rails
-- + Agent DB today; this is a THIRD store holding traveller text, so it needs
-- adding to that path -- see the note at the bottom of this file.
CREATE TABLE IF NOT EXISTS aroundtrail.chat_texts
(
    event_time      DateTime64(3)                CODEC(Delta, ZSTD(1)),
    event_date      Date MATERIALIZED toDate(event_time),

    conversation_id String,
    request_id      String,
    trace_id        String DEFAULT '',
    country_slug    LowCardinality(String),

    prompt          String CODEC(ZSTD(3)),
    completion      String CODEC(ZSTD(3)),
    -- The sentences the link-or-drop filter removed. finalize.py already caps
    -- these at 12 x 200 chars for trace metadata; same bound applies here.
    dropped_samples Array(String) CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (country_slug, event_time)
TTL event_date + INTERVAL 90 DAY DELETE
SETTINGS index_granularity = 8192;

ALTER TABLE aroundtrail.chat_texts
    ADD INDEX IF NOT EXISTS idx_conversation conversation_id TYPE bloom_filter(0.01) GRANULARITY 4;

-- ---------------------------------------------------------------------------
-- Verify the TTLs actually attached -- both should return a non-empty expression.
-- ---------------------------------------------------------------------------
-- SELECT table, engine_full FROM system.tables
--  WHERE database = 'aroundtrail' AND table LIKE 'chat_%';

-- ---------------------------------------------------------------------------
-- OPEN ITEM -- DSAR
-- ---------------------------------------------------------------------------
-- `make dsar-export` / `make dsar-erase` abort without AGENT_DATABASE_URL
-- precisely so a Rails-only export cannot look clean while Agent DB rows
-- survive. chat_texts creates the same hazard a third time. Two ways out:
--   (a) add a ClickHouse leg to both tasks, keyed by conversation_id resolved
--       from the Agent DB for that user; or
--   (b) never write anything to chat_texts that can be tied back to a person
--       -- which conversation_id CAN be, via conversations.user_id.
-- (a) is the honest one. This is NOT done, and shipping chat_texts without it
-- means the DSAR erase is incomplete.
