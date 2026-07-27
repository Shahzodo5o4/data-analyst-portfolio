-- ============================================================================
-- 01 - Baseline: what does normal look like?
-- ============================================================================
-- Before asking why something is wrong, establish what "normal" is. Every later
-- query compares against the numbers produced here.
--
-- Run:  psql -d portfolio -f sql/01-baseline.sql
-- ============================================================================

\echo '\n== Portfolio of the book =='

SELECT
    (SELECT count(*) FROM uzcard.customers)    AS customers,
    (SELECT count(*) FROM uzcard.cards)        AS cards,
    (SELECT count(*) FROM uzcard.merchants)    AS merchants,
    (SELECT count(*) FROM uzcard.terminals)    AS terminals,
    (SELECT count(*) FROM uzcard.transactions) AS transactions,
    (SELECT min(txn_ts)::date FROM uzcard.transactions) AS first_txn,
    (SELECT max(txn_ts)::date FROM uzcard.transactions) AS last_txn;


\echo '\n== Transaction outcomes =='

SELECT
    txn_status,
    count(*)                                            AS txns,
    round(100.0 * count(*) / sum(count(*)) OVER (), 2)  AS pct,
    to_char(sum(amount_uzs), '999,999,999,999')         AS total_uzs
FROM uzcard.transactions
GROUP BY txn_status
ORDER BY txns DESC;


\echo '\n== Why transactions are declined =='
-- decline_reason is NULL on approved rows by design, so the denominator here is
-- declined transactions only, not all transactions.

SELECT
    decline_reason,
    count(*)                                           AS declines,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct_of_declines
FROM uzcard.transactions
WHERE txn_status = 'declined'
GROUP BY decline_reason
ORDER BY declines DESC;


\echo '\n== Where payments happen: terminal channel, not entry mode =='
-- entry_mode collapses ATM, P2P and chip-at-POS into a single "chip" bucket, which
-- hides three very different behaviours. terminals.channel keeps them apart and is
-- the dimension used throughout this analysis.

SELECT
    te.channel,
    count(*)                                                AS txns,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)      AS pct_of_txns,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY t.amount_uzs)
        FILTER (WHERE t.txn_status = 'approved')::bigint    AS median_ticket_uzs,
    round(100.0 * count(*) FILTER (WHERE t.txn_status = 'declined')
          / count(*), 2)                                    AS decline_pct,
    round(100.0 * count(*) FILTER (WHERE t.is_disputed)
          / nullif(count(*) FILTER (WHERE t.txn_status = 'approved'), 0), 3) AS dispute_pct
FROM uzcard.transactions t
JOIN uzcard.terminals te ON te.terminal_id = t.terminal_id
GROUP BY te.channel
ORDER BY txns DESC;


\echo '\n== Customer book =='

SELECT
    customer_segment,
    count(*)                                           AS customers,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM uzcard.customers
GROUP BY customer_segment
ORDER BY customers DESC;


\echo '\n== Card book: three product tiers =='

SELECT
    product_tier,
    count(*)                                            AS cards,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)  AS pct,
    count(*) FILTER (WHERE credit_limit = 0)            AS zero_limit_cards,
    round(100.0 * count(*) FILTER (WHERE status <> 'active') / count(*), 1) AS non_active_pct
FROM uzcard.cards
GROUP BY product_tier
ORDER BY cards DESC;
