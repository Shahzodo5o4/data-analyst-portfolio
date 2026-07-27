-- ============================================================================
-- 04 - Channel shift: where the business is moving
-- ============================================================================
-- The customer book onboards throughout 2023, so raw month-over-month growth is
-- meaningless here - every channel "grows" simply because there are more cards
-- each month. Growth is therefore measured as SHARE of monthly volume, which is
-- immune to the size of the book.
--
-- Granularity is monthly on purpose: 26 calendar days are missing from the year
-- (see setup/DATA-QUALITY.md), so a daily series would show dips that are not real.
--
-- Run:  psql -d portfolio -f sql/04-channel-shift.sql
-- ============================================================================

\echo '\n== The trap: absolute volume says everything is booming =='

WITH monthly AS (
    SELECT
        date_trunc('month', t.txn_ts)::date AS month,
        te.channel,
        count(*)                            AS txns
    FROM uzcard.transactions t
    JOIN uzcard.terminals te ON te.terminal_id = t.terminal_id
    GROUP BY 1, 2
)
SELECT
    channel,
    min(txns) FILTER (WHERE month = '2023-01-01')                       AS jan_txns,
    min(txns) FILTER (WHERE month = '2023-12-01')                       AS dec_txns,
    round(1.0 * min(txns) FILTER (WHERE month = '2023-12-01')
          / nullif(min(txns) FILTER (WHERE month = '2023-01-01'), 0), 1) AS growth_x
FROM monthly
GROUP BY channel
ORDER BY growth_x DESC;

-- Every channel multiplies several times over. This is the book growing, not the
-- mix changing, and quoting these numbers as "growth" would be misleading.


\echo '\n== The honest view: share of each month =='

WITH monthly AS (
    SELECT
        date_trunc('month', t.txn_ts)::date AS month,
        te.channel,
        count(*)                            AS txns
    FROM uzcard.transactions t
    JOIN uzcard.terminals te ON te.terminal_id = t.terminal_id
    GROUP BY 1, 2
)
SELECT
    month,
    round(100.0 * sum(txns) FILTER (WHERE channel = 'POS')  / sum(txns), 1) AS pos_pct,
    round(100.0 * sum(txns) FILTER (WHERE channel = 'ECOM') / sum(txns), 1) AS ecom_pct,
    round(100.0 * sum(txns) FILTER (WHERE channel = 'QR')   / sum(txns), 1) AS qr_pct,
    round(100.0 * sum(txns) FILTER (WHERE channel = 'ATM')  / sum(txns), 1) AS atm_pct,
    round(100.0 * sum(txns) FILTER (WHERE channel = 'P2P')  / sum(txns), 1) AS p2p_pct,
    sum(txns)                                                               AS total_txns
FROM monthly
GROUP BY month
ORDER BY month;


\echo '\n== Share shift, first quarter vs last quarter =='
-- Comparing quarters rather than single months keeps one unusual December from
-- carrying the whole conclusion.

WITH q AS (
    SELECT
        te.channel,
        count(*) FILTER (WHERE t.txn_ts <  '2023-04-01')                  AS q1_txns,
        count(*) FILTER (WHERE t.txn_ts >= '2023-10-01')                  AS q4_txns
    FROM uzcard.transactions t
    JOIN uzcard.terminals te ON te.terminal_id = t.terminal_id
    GROUP BY te.channel
)
SELECT
    channel,
    round(100.0 * q1_txns / sum(q1_txns) OVER (), 1)                      AS q1_share_pct,
    round(100.0 * q4_txns / sum(q4_txns) OVER (), 1)                      AS q4_share_pct,
    round(100.0 * q4_txns / sum(q4_txns) OVER ()
          - 100.0 * q1_txns / sum(q1_txns) OVER (), 1)                    AS shift_pts
FROM q
ORDER BY shift_pts DESC;


\echo '\n== Month-over-month share change, to locate the inflection =='

WITH monthly AS (
    SELECT
        date_trunc('month', t.txn_ts)::date AS month,
        te.channel,
        count(*)                            AS txns
    FROM uzcard.transactions t
    JOIN uzcard.terminals te ON te.terminal_id = t.terminal_id
    GROUP BY 1, 2
),
shares AS (
    SELECT
        month,
        channel,
        100.0 * txns / sum(txns) OVER (PARTITION BY month) AS share_pct
    FROM monthly
)
SELECT
    month,
    round(share_pct, 1)                                                  AS ecom_share_pct,
    round(share_pct - lag(share_pct) OVER (ORDER BY month), 1)           AS change_vs_prev_month
FROM shares
WHERE channel = 'ECOM'
ORDER BY month;


\echo '\n== Why the shift matters: risk moves with it =='
-- Combining the two halves of the analysis: the channel gaining share is also the
-- channel that produces almost every dispute.

SELECT
    te.channel,
    round(100.0 * count(*) FILTER (WHERE t.txn_ts >= '2023-10-01')
          / sum(count(*) FILTER (WHERE t.txn_ts >= '2023-10-01')) OVER (), 1) AS q4_share_pct,
    round(100.0 * count(*) FILTER (WHERE t.is_disputed)
          / nullif(count(*) FILTER (WHERE t.txn_status = 'approved'), 0), 3)  AS dispute_pct,
    round(100.0 * count(*) FILTER (WHERE t.is_disputed)
          / sum(count(*) FILTER (WHERE t.is_disputed)) OVER (), 1)            AS pct_of_all_disputes
FROM uzcard.transactions t
JOIN uzcard.terminals te ON te.terminal_id = t.terminal_id
GROUP BY te.channel
ORDER BY q4_share_pct DESC;
