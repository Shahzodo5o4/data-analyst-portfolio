-- Portfolio analysis database: one schema per project.
--
-- Primary keys are declared because they are guaranteed by the source systems and a
-- violation means the extract itself is broken. Foreign keys are deliberately NOT
-- declared: whether every child row points at a parent that actually exists is one of
-- the questions the data-quality pass has to answer, and a failed load would hide that
-- answer instead of reporting it.

DROP SCHEMA IF EXISTS uzcard, merchanthub, walletapp, oqpay CASCADE;

CREATE SCHEMA uzcard;      -- Track A: card issuing / payment processing
CREATE SCHEMA merchanthub; -- Track C: acquiring, settlements, disputes
CREATE SCHEMA walletapp;   -- Track B: wallet app funnel, subscriptions, retention
CREATE SCHEMA oqpay;       -- Track D: super-app marketplace, delivery, support


-- ============================================================ uzcard (Track A)

CREATE TABLE uzcard.customers (
    customer_id      INTEGER PRIMARY KEY,
    full_name        TEXT,
    birth_date       DATE,
    gender           TEXT,
    region           TEXT,
    customer_segment TEXT,
    onboarding_date  DATE,
    income_band      TEXT
);

CREATE TABLE uzcard.cards (
    card_id      INTEGER PRIMARY KEY,
    customer_id  INTEGER,
    card_type    TEXT,
    product_tier TEXT,
    issue_date   DATE,
    expiry_date  DATE,
    status       TEXT,
    credit_limit BIGINT
);

CREATE TABLE uzcard.mcc_categories (
    mcc_code       INTEGER PRIMARY KEY,
    category_name  TEXT,
    category_group TEXT,
    is_high_risk   BOOLEAN
);

CREATE TABLE uzcard.merchants (
    merchant_id         INTEGER PRIMARY KEY,
    merchant_name       TEXT,
    mcc_code            INTEGER,
    region              TEXT,
    onboarding_date     DATE,
    risk_tier           TEXT,
    avg_ticket_expected BIGINT
);

CREATE TABLE uzcard.terminals (
    terminal_id    INTEGER PRIMARY KEY,
    merchant_id    INTEGER,
    channel        TEXT,
    device_city    TEXT,
    activated_date DATE,
    is_active      BOOLEAN
);

CREATE TABLE uzcard.transactions (
    transaction_id INTEGER PRIMARY KEY,
    card_id        INTEGER,
    merchant_id    INTEGER,
    terminal_id    INTEGER,
    txn_ts         TIMESTAMP,
    amount_uzs     BIGINT,
    txn_status     TEXT,
    decline_reason TEXT,
    is_recurring   BOOLEAN,
    entry_mode     TEXT,
    is_disputed    BOOLEAN
);


-- ============================================================ merchanthub (Track C)

CREATE TABLE merchanthub.regions (
    region_id     INTEGER PRIMARY KEY,
    region_name   TEXT,
    macro_zone    TEXT,
    population_k  INTEGER
);

CREATE TABLE merchanthub.merchant_categories (
    category_id   INTEGER PRIMARY KEY,
    mcc           INTEGER,
    category_name TEXT,
    risk_tier     TEXT
);

CREATE TABLE merchanthub.merchants (
    merchant_id             INTEGER PRIMARY KEY,
    legal_name              TEXT,
    brand_name              TEXT,
    category_id             INTEGER,
    region_id               INTEGER,
    onboarded_date          DATE,
    size_band               TEXT,
    settlement_account_bank TEXT,
    status                  TEXT
);

CREATE TABLE merchanthub.terminals (
    terminal_id    INTEGER PRIMARY KEY,
    merchant_id    INTEGER,
    terminal_type  TEXT,
    region_id      INTEGER,
    device_model   TEXT,
    activated_date DATE,
    is_active      BOOLEAN
);

CREATE TABLE merchanthub.settlements (
    settlement_id    INTEGER PRIMARY KEY,
    merchant_id      INTEGER,
    batch_date       DATE,
    settled_ts       TIMESTAMP,
    gross_amount_uzs BIGINT,
    commission_uzs   BIGINT,
    net_amount_uzs   BIGINT,
    holdback_uzs     BIGINT
);

-- settlement_id arrives as "10835.0" in the extract, so it cannot be copied straight
-- into INTEGER. It is loaded as DOUBLE PRECISION and converted after the COPY; see
-- load_data.py. The float formatting itself is recorded as a data-quality finding.
CREATE TABLE merchanthub.transactions (
    txn_id          INTEGER PRIMARY KEY,
    terminal_id     INTEGER,
    txn_ts          TIMESTAMP,
    amount_uzs      BIGINT,
    status          TEXT,
    auth_response   TEXT,
    card_scheme     TEXT,
    is_cross_region BOOLEAN,
    settlement_id   DOUBLE PRECISION
);

CREATE TABLE merchanthub.disputes (
    dispute_id         INTEGER PRIMARY KEY,
    txn_id             INTEGER,
    opened_date        DATE,
    reason_code        TEXT,
    dispute_type       TEXT,
    dispute_amount_uzs BIGINT,
    status             TEXT,
    resolved_date      DATE
);


-- ============================================================ walletapp (Track B)

CREATE TABLE walletapp.channels (
    channel_id       INTEGER PRIMARY KEY,
    channel_name     TEXT,
    cost_per_install NUMERIC
);

CREATE TABLE walletapp.plans (
    plan_id       INTEGER PRIMARY KEY,
    plan_name     TEXT,
    monthly_price NUMERIC,
    is_paid       BOOLEAN
);

CREATE TABLE walletapp.users (
    user_id    INTEGER PRIMARY KEY,
    signup_ts  TIMESTAMP,
    channel_id INTEGER,
    region     TEXT,
    device_os  TEXT,
    age        INTEGER
);

CREATE TABLE walletapp.subscriptions (
    subscription_id INTEGER PRIMARY KEY,
    user_id         INTEGER,
    plan_id         INTEGER,
    started_at      TIMESTAMP,
    status          TEXT,
    canceled_at     TIMESTAMP
);

CREATE TABLE walletapp.charges (
    charge_id       INTEGER PRIMARY KEY,
    subscription_id INTEGER,
    user_id         INTEGER,
    charged_at      TIMESTAMP,
    amount          NUMERIC,
    status          TEXT
);

CREATE TABLE walletapp.app_events (
    event_id   INTEGER PRIMARY KEY,
    user_id    INTEGER,
    event_type TEXT,
    event_ts   TIMESTAMP,
    amount     NUMERIC
);


-- ============================================================ oqpay (Track D)

CREATE TABLE oqpay.categories (
    category_id   INTEGER PRIMARY KEY,
    category_name TEXT,
    cluster       TEXT
);

CREATE TABLE oqpay.merchants (
    merchant_id   INTEGER PRIMARY KEY,
    merchant_name TEXT,
    home_city     TEXT,
    joined_date   DATE,
    size_band     TEXT
);

CREATE TABLE oqpay.products (
    product_id   INTEGER PRIMARY KEY,
    merchant_id  INTEGER,
    category_id  INTEGER,
    product_name TEXT,
    price        BIGINT
);

CREATE TABLE oqpay.users (
    user_id     INTEGER PRIMARY KEY,
    signup_ts   TIMESTAMP,
    city        TEXT,
    device_os   TEXT,
    acq_channel TEXT,
    age         INTEGER
);

CREATE TABLE oqpay.couriers (
    courier_id   INTEGER PRIMARY KEY,
    city         TEXT,
    vehicle_type TEXT,
    active       BOOLEAN
);

CREATE TABLE oqpay.orders (
    order_id     INTEGER PRIMARY KEY,
    user_id      INTEGER,
    ordered_ts   TIMESTAMP,
    city         TEXT,
    status       TEXT,
    total_amount BIGINT,
    item_count   INTEGER
);

CREATE TABLE oqpay.order_items (
    order_item_id INTEGER PRIMARY KEY,
    order_id      INTEGER,
    product_id    INTEGER,
    quantity      INTEGER,
    unit_price    BIGINT
);

CREATE TABLE oqpay.payments (
    payment_id INTEGER PRIMARY KEY,
    order_id   INTEGER,
    user_id    INTEGER,
    method     TEXT,
    amount     BIGINT,
    status     TEXT,
    attempt_no INTEGER,
    paid_ts    TIMESTAMP
);

CREATE TABLE oqpay.deliveries (
    delivery_id  INTEGER PRIMARY KEY,
    order_id     INTEGER,
    courier_id   INTEGER,
    promised_ts  TIMESTAMP,
    delivered_ts TIMESTAMP,
    status       TEXT
);

CREATE TABLE oqpay.reviews (
    review_id  INTEGER PRIMARY KEY,
    order_id   INTEGER,
    user_id    INTEGER,
    rating     INTEGER,
    review_ts  TIMESTAMP
);

-- The behavioural clickstream: the largest table in the portfolio at ~780k rows.
-- product_id is only populated for product-level events (view, add_to_cart), so it is
-- nullable by design rather than by accident.
CREATE TABLE oqpay.events (
    event_id   INTEGER PRIMARY KEY,
    user_id    INTEGER,
    event_ts   TIMESTAMP,
    event_type TEXT,
    product_id INTEGER
);

CREATE TABLE oqpay.support_tickets (
    ticket_id   INTEGER PRIMARY KEY,
    user_id     INTEGER,
    order_id    INTEGER,
    opened_ts   TIMESTAMP,
    reason      TEXT,
    status      TEXT,
    resolved_ts TIMESTAMP
);


-- ============================================================ indexes
-- Only on the join and filter columns the analyses actually use.

CREATE INDEX ON uzcard.transactions (card_id);
CREATE INDEX ON uzcard.transactions (merchant_id);
CREATE INDEX ON uzcard.transactions (terminal_id);
CREATE INDEX ON uzcard.transactions (txn_ts);
CREATE INDEX ON uzcard.cards (customer_id);

CREATE INDEX ON merchanthub.transactions (terminal_id);
CREATE INDEX ON merchanthub.transactions (txn_ts);
CREATE INDEX ON merchanthub.transactions (settlement_id);
CREATE INDEX ON merchanthub.disputes (txn_id);
CREATE INDEX ON merchanthub.settlements (merchant_id);
CREATE INDEX ON merchanthub.terminals (merchant_id);

CREATE INDEX ON walletapp.app_events (user_id);
CREATE INDEX ON walletapp.app_events (event_ts);
CREATE INDEX ON walletapp.app_events (event_type);
CREATE INDEX ON walletapp.subscriptions (user_id);
CREATE INDEX ON walletapp.charges (subscription_id);

CREATE INDEX ON oqpay.events (user_id);
CREATE INDEX ON oqpay.events (event_ts);
CREATE INDEX ON oqpay.events (event_type);
CREATE INDEX ON oqpay.orders (user_id);
CREATE INDEX ON oqpay.orders (ordered_ts);
CREATE INDEX ON oqpay.order_items (order_id);
CREATE INDEX ON oqpay.order_items (product_id);
CREATE INDEX ON oqpay.payments (order_id);
CREATE INDEX ON oqpay.deliveries (order_id);
CREATE INDEX ON oqpay.reviews (order_id);
CREATE INDEX ON oqpay.support_tickets (order_id);
