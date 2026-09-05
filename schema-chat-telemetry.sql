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
    -- See the same column in schema-site-events.sql: laptop turns and production
    -- turns share these tables, and this is what keeps them apart.
    environment         LowCardinality(String) DEFAULT 'production',
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
    -- WHICH tools, in call ORDER (added 2026-09-05, when the sink was built).
    -- Ordered, not a set: "searched, found nothing, searched again" and
    -- "searched once" are the same set and very different turns. Capped at 64
    -- names per turn in stream.py -- a turn near that is a ReAct loop, which
    -- tool_calls already reports without repeating the names.
    tool_names          Array(LowCardinality(String)),

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
--   environment    2 values
--   country_slug   ~6
--   intent         ~4
--   grounding_outcome ~5
--   event_time     high
--
-- Chosen because every real question filters country -> intent -> outcome ->
-- window, e.g. "grounding pass rate for nepal plan turns last week". Queries
-- MUST include environment + country_slug to get index pruning (schema-pk-filter-on-orderby);
-- a query filtering only on intent scans everything.
ORDER BY (environment, country_slug, intent, grounding_outcome, event_time)
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
    environment     LowCardinality(String) DEFAULT 'production',

    prompt          String CODEC(ZSTD(3)),
    completion      String CODEC(ZSTD(3)),
    -- The sentences the link-or-drop filter removed. finalize.py already caps
    -- these at 12 x 200 chars for trace metadata; same bound applies here.
    dropped_samples Array(String) CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (environment, country_slug, event_time)
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

-- ---------------------------------------------------------------------------
-- chat_tool_calls -- ONE ROW PER TOOL CALL. Added 2026-09-05.
-- ---------------------------------------------------------------------------
-- `chat_turns.tool_names` records that a turn called
-- `search_destinations -> search_destinations`. It cannot say whether that was
-- "Kathmandu" then "Pokhara" (correct: two cities) or "Kathmandu" twice (the
-- agent re-asking because the first returned nothing). Those are the same row
-- there and OPPOSITE findings, which is the gap this table closes.
--
-- 90-DAY TTL, matching chat_texts rather than chat_turns' 24 months. `args` is
-- model-composed FROM the traveller's question and echoes it closely -- a search
-- for "short treks near Pokhara" carries the question in it. Putting that on the
-- metrics clock would quietly keep traveller-derived text for two years, past
-- the window frontend-nepal/src/app/privacy/page.tsx publishes.
--
-- The long-horizon question survives the shorter window: "which tool sequences
-- correlate with dropped grounding" is answerable from chat_turns.tool_names,
-- which keeps its 24 months. This table is the DETAIL view, and detail is what
-- you look at recently.
CREATE TABLE IF NOT EXISTS aroundtrail.chat_tool_calls
(
    event_time      DateTime64(3)                CODEC(Delta, ZSTD(1)),
    event_date      Date MATERIALIZED toDate(event_time),

    -- request_id joins to BOTH chat_turns and chat_texts; seq restores order
    -- within the turn, which is the whole point of the table.
    request_id      String,
    conversation_id String,
    trace_id        String DEFAULT '',
    seq             UInt16 DEFAULT 0,

    country_slug    LowCardinality(String),
    environment     LowCardinality(String) DEFAULT 'production',
    -- LowCardinality: the tool set is a fixed vocabulary of ~15 names.
    tool_name       LowCardinality(String),

    -- The tool's arguments as JSON. Bounded in the sink -- an unbounded blob
    -- here is how a single pathological turn becomes a large part.
    args            String CODEC(ZSTD(3)),

    -- WHAT CAME BACK, without storing whole result sets. result_count answers
    -- "did it find anything" (a 0 is the signal that explains a retry), and the
    -- slugs answer "did it find the RIGHT thing" for the first handful.
    result_count    UInt16 DEFAULT 0,
    result_slugs    Array(String) CODEC(ZSTD(3)),

    -- Per-call latency, paired off the LangGraph run_id between on_tool_start
    -- and on_tool_end. chat_turns.latency_ms is the whole streamed turn; this
    -- is what says WHICH tool owned it.
    duration_ms     UInt32 DEFAULT 0,
    error           String DEFAULT ''
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
-- Same low-to-high-with-time-last rule as the other two, and the same
-- consequence: a query that does not filter environment + country_slug scans
-- everything. tool_name sits third because "how does search_trails behave" is
-- the question this table exists for.
ORDER BY (environment, country_slug, tool_name, event_time)
TTL event_date + INTERVAL 90 DAY DELETE
SETTINGS index_granularity = 8192;

-- Joining a turn to its calls skips the ORDER BY prefix entirely.
ALTER TABLE aroundtrail.chat_tool_calls
    ADD INDEX IF NOT EXISTS idx_request request_id TYPE bloom_filter(0.01) GRANULARITY 4;

-- ---------------------------------------------------------------------------
-- chat_log -- the ClickStack/HyperDX source. Added 2026-09-05.
-- ---------------------------------------------------------------------------
-- Why a view: HyperDX's "Log" source type expects an OTel-log-shaped table, and
-- these three are hand-rolled MergeTrees in a different database that ClickStack
-- knows nothing about. Naming the columns EXACTLY as `otel.otel_logs` names them
-- (Timestamp / Body / SeverityText / ServiceName / LogAttributes /
-- ResourceAttributes) is what lets every field in the source form point at a real
-- column. **Leave no expression field blank in that form** -- HyperDX interpolates
-- an expression as a PREFIX, so an empty one becomes a bare `.foo` and errors.
--
-- LEFT JOIN, not INNER, in both directions from chat_turns: chat_texts and
-- chat_tool_calls expire at 90 days while chat_turns keeps 24 months. An inner
-- join would make a turn's metrics VANISH on the day its text expired, which
-- reads as data loss and is actually the retention design working.
CREATE OR REPLACE VIEW aroundtrail.chat_log AS
WITH tools AS (
    SELECT
        request_id,
        -- Readable in a log feed and searchable as a substring, which an
        -- Array(Tuple) would not be.
        arrayStringConcat(
            groupArray(concat(tool_name, '(', args, ') -> ', toString(result_count))),
            '  |  '
        ) AS tool_detail,
        sum(duration_ms) AS tool_ms
    FROM aroundtrail.chat_tool_calls
    GROUP BY request_id
)
SELECT
    t.event_time            AS Timestamp,
    -- Body is the log line. The traveller's question is the most useful thing
    -- to read in a feed, and making it Body is what makes free-text search
    -- search the question.
    x.prompt                AS Body,
    -- Colour-codes the feed so the turns worth looking at surface themselves.
    multiIf(t.grounding_outcome = 'error', 'error',
            t.grounding_outcome IN ('dropped', 'no_evidence'), 'warn',
            t.grounding_outcome = 'clarify', 'debug',
            'info')         AS SeverityText,
    -- Makes HyperDX's service filter an intent filter for free.
    concat(t.country_slug, '-', t.intent) AS ServiceName,
    -- Points at LANGFUSE, not at otel.otel_traces. Do NOT wire a correlated
    -- trace source to it -- the id would resolve to nothing. It is here so a
    -- turn can be opened in Langfuse by hand while the two are compared.
    t.trace_id              AS TraceId,
    t.request_id            AS SpanId,
    map(
        'environment',        t.environment,
        'country_slug',       t.country_slug,
        'intent',             t.intent,
        'source',             t.source,
        'trip_subtype',       t.trip_subtype,
        'grounding_outcome',  t.grounding_outcome,
        'tool_path',          arrayStringConcat(t.tool_names, ' -> '),
        'tool_detail',        coalesce(tl.tool_detail, ''),
        'tool_ms',            toString(coalesce(tl.tool_ms, 0)),
        'tool_calls',         toString(t.tool_calls),
        'tool_messages_total',toString(t.tool_messages_total),
        'answer_delivered',   toString(t.answer_delivered),
        'grounding_pass',     toString(t.grounding_pass),
        'has_links',          toString(t.has_links),
        'scores_applied',     toString(t.scores_applied),
        'filter_ran',         toString(t.filter_ran),
        'deleted_pct',        toString(t.deleted_pct),
        'dropped_sentences',  toString(t.dropped_sentences),
        'answer_len',         toString(t.answer_len),
        'latency_ms',         toString(t.latency_ms),
        'conversation_id',    t.conversation_id,
        'error',              t.error
    )                       AS LogAttributes,
    map('service.name', concat(t.country_slug, '-', t.intent)) AS ResourceAttributes,
    t.tool_names            AS tool_names,
    coalesce(tl.tool_detail, '') AS tool_detail,
    t.latency_ms            AS latency_ms,
    t.intent                AS intent,
    t.grounding_outcome     AS grounding_outcome,
    t.environment           AS environment,
    t.country_slug          AS country_slug,
    t.conversation_id       AS conversation_id,
    x.completion            AS completion,
    x.dropped_samples       AS dropped_samples
FROM aroundtrail.chat_turns AS t
LEFT JOIN aroundtrail.chat_texts AS x USING (request_id)
LEFT JOIN tools AS tl USING (request_id);
