-- Creative Ledger: hybrid PostgreSQL schema
-- Layers: shared core + CTI subtypes + constrained JSONB + EAV-lite + decoupled settlement + derived read model
-- Run:  psql -v ON_ERROR_STOP=1 -d creative -f sql/schema.sql

DROP MATERIALIZED VIEW IF EXISTS mv_transactions_flat;
DROP TABLE IF EXISTS custom_field_value, custom_field_def, transaction_settlements, settlements,
  commission_detail, direct_sale_detail, royalty_detail, subscription_detail,
  grant_detail, barter_detail, platform_payout_detail,
  transactions, channels, counterparties CASCADE;

-- ---------- Registries ----------
CREATE TABLE counterparties (counterparty_id BIGSERIAL PRIMARY KEY, name VARCHAR(120) NOT NULL);
CREATE TABLE channels       (channel_id      BIGSERIAL PRIMARY KEY, name VARCHAR(80)  NOT NULL);

-- ---------- Shared transaction core ----------
CREATE TABLE transactions (
  transaction_id     BIGSERIAL PRIMARY KEY,
  transaction_type   VARCHAR(30) NOT NULL
    CHECK (transaction_type IN ('commission','direct_sale','royalty','subscription','grant','barter','platform_payout')),
  event_date         TIMESTAMPTZ NOT NULL DEFAULT now(),
  gross_amount       NUMERIC(18,2) NOT NULL CHECK (gross_amount >= 0),
  fee_amount         NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
  tax_withheld       NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_withheld >= 0),
  net_amount         NUMERIC(18,2) NOT NULL,
  currency_code      CHAR(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
  status             VARCHAR(30) NOT NULL DEFAULT 'pending',
  counterparty_id    BIGINT REFERENCES counterparties,
  channel_id         BIGINT REFERENCES channels,
  external_reference VARCHAR(120),
  metadata           JSONB NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT net_identity CHECK (net_amount = gross_amount - fee_amount - tax_withheld),
  CONSTRAINT metadata_ok CHECK (
    jsonb_typeof(metadata) = 'object'
    AND NOT metadata ?| ARRAY['gross_amount','fee_amount','tax_withheld','net_amount','currency','transaction_type']),
  CONSTRAINT uq_tx_type UNIQUE (transaction_id, transaction_type)
);
CREATE INDEX idx_tx_date ON transactions (event_date);
CREATE INDEX idx_tx_type ON transactions (transaction_type);
CREATE INDEX idx_tx_meta ON transactions USING GIN (metadata jsonb_path_ops);

-- ---------- CTI subtype tables (type-guarded by composite FK) ----------
CREATE TABLE commission_detail (
  transaction_id BIGINT PRIMARY KEY,
  transaction_type VARCHAR(30) NOT NULL DEFAULT 'commission' CHECK (transaction_type = 'commission'),
  client VARCHAR(120) NOT NULL, category VARCHAR(40) NOT NULL,
  milestones INT NOT NULL CHECK (milestones > 0), delivery_date DATE NOT NULL,
  FOREIGN KEY (transaction_id, transaction_type) REFERENCES transactions (transaction_id, transaction_type) ON DELETE CASCADE);

CREATE TABLE direct_sale_detail (
  transaction_id BIGINT PRIMARY KEY,
  transaction_type VARCHAR(30) NOT NULL DEFAULT 'direct_sale' CHECK (transaction_type = 'direct_sale'),
  product VARCHAR(120) NOT NULL, sale_channel VARCHAR(60) NOT NULL,
  quantity INT NOT NULL CHECK (quantity > 0),
  fulfilment VARCHAR(20) NOT NULL CHECK (fulfilment IN ('pending','shipped','delivered')),
  FOREIGN KEY (transaction_id, transaction_type) REFERENCES transactions (transaction_id, transaction_type) ON DELETE CASCADE);

CREATE TABLE royalty_detail (
  transaction_id BIGINT PRIMARY KEY,
  transaction_type VARCHAR(30) NOT NULL DEFAULT 'royalty' CHECK (transaction_type = 'royalty'),
  work_id VARCHAR(60) NOT NULL,
  rights_type VARCHAR(40) NOT NULL CHECK (rights_type IN ('print','digital','licensing','performance')),
  period VARCHAR(20) NOT NULL, rate_basis VARCHAR(40) NOT NULL,
  FOREIGN KEY (transaction_id, transaction_type) REFERENCES transactions (transaction_id, transaction_type) ON DELETE CASCADE);

CREATE TABLE subscription_detail (
  transaction_id BIGINT PRIMARY KEY,
  transaction_type VARCHAR(30) NOT NULL DEFAULT 'subscription' CHECK (transaction_type = 'subscription'),
  plan VARCHAR(60) NOT NULL,
  billing_period VARCHAR(20) NOT NULL CHECK (billing_period IN ('monthly','quarterly','annual')),
  subscriber_ref VARCHAR(80) NOT NULL,
  FOREIGN KEY (transaction_id, transaction_type) REFERENCES transactions (transaction_id, transaction_type) ON DELETE CASCADE);

CREATE TABLE grant_detail (
  transaction_id BIGINT PRIMARY KEY,
  transaction_type VARCHAR(30) NOT NULL DEFAULT 'grant' CHECK (transaction_type = 'grant'),
  grantor VARCHAR(120) NOT NULL, programme VARCHAR(120) NOT NULL,
  award_ref VARCHAR(60) NOT NULL, deadline DATE NOT NULL,
  FOREIGN KEY (transaction_id, transaction_type) REFERENCES transactions (transaction_id, transaction_type) ON DELETE CASCADE);

CREATE TABLE barter_detail (
  transaction_id BIGINT PRIMARY KEY,
  transaction_type VARCHAR(30) NOT NULL DEFAULT 'barter' CHECK (transaction_type = 'barter'),
  item_received VARCHAR(120) NOT NULL,
  fair_value NUMERIC(18,2) NOT NULL CHECK (fair_value >= 0),
  exchange_ref VARCHAR(60) NOT NULL,
  FOREIGN KEY (transaction_id, transaction_type) REFERENCES transactions (transaction_id, transaction_type) ON DELETE CASCADE);

CREATE TABLE platform_payout_detail (
  transaction_id BIGINT PRIMARY KEY,
  transaction_type VARCHAR(30) NOT NULL DEFAULT 'platform_payout' CHECK (transaction_type = 'platform_payout'),
  platform VARCHAR(60) NOT NULL, payout_ref VARCHAR(60) NOT NULL, batch_ref VARCHAR(60) NOT NULL,
  FOREIGN KEY (transaction_id, transaction_type) REFERENCES transactions (transaction_id, transaction_type) ON DELETE CASCADE);

-- ---------- Gap G2: a transaction must have its subtype row (checked at commit) ----------
CREATE FUNCTION chk_subtype_exists() RETURNS trigger AS $$
DECLARE ok boolean;
BEGIN
  EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I WHERE transaction_id = $1)', NEW.transaction_type || '_detail')
    INTO ok USING NEW.transaction_id;
  IF NOT ok THEN
    RAISE EXCEPTION 'transaction % (%) has no subtype row', NEW.transaction_id, NEW.transaction_type;
  END IF;
  RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_subtype_exists AFTER INSERT ON transactions
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION chk_subtype_exists();

-- ---------- EAV-lite for runtime-defined fields (Gap G1: type-guarded by composite FKs) ----------
CREATE TABLE custom_field_def (
  field_id BIGSERIAL PRIMARY KEY,
  field_name VARCHAR(60) NOT NULL,
  transaction_type VARCHAR(30) NOT NULL
    CHECK (transaction_type IN ('commission','direct_sale','royalty','subscription','grant','barter','platform_payout')),
  data_type VARCHAR(10) NOT NULL CHECK (data_type IN ('num','text','date','bool')),
  UNIQUE (field_id, transaction_type));

CREATE TABLE custom_field_value (
  field_id BIGINT NOT NULL, transaction_id BIGINT NOT NULL, transaction_type VARCHAR(30) NOT NULL,
  num_value NUMERIC, text_value TEXT, date_value DATE, bool_value BOOLEAN,
  PRIMARY KEY (field_id, transaction_id),
  FOREIGN KEY (field_id, transaction_type) REFERENCES custom_field_def (field_id, transaction_type),
  FOREIGN KEY (transaction_id, transaction_type) REFERENCES transactions (transaction_id, transaction_type) ON DELETE CASCADE,
  CHECK (num_nonnulls(num_value, text_value, date_value, bool_value) = 1));

-- ---------- Decoupled settlement (many-to-many) ----------
CREATE TABLE settlements (
  settlement_id BIGSERIAL PRIMARY KEY,
  initiated_at TIMESTAMPTZ NOT NULL DEFAULT now(), cleared_at TIMESTAMPTZ,
  destination_account VARCHAR(80) NOT NULL,
  settled_amount NUMERIC(18,2) NOT NULL CHECK (settled_amount > 0),
  currency_code CHAR(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
  reconciliation_status VARCHAR(20) NOT NULL DEFAULT 'open');

CREATE TABLE transaction_settlements (
  transaction_id BIGINT NOT NULL REFERENCES transactions ON DELETE CASCADE,
  settlement_id  BIGINT NOT NULL REFERENCES settlements  ON DELETE CASCADE,
  allocated_amount NUMERIC(18,2) NOT NULL CHECK (allocated_amount > 0),
  PRIMARY KEY (transaction_id, settlement_id));

-- Gap G4: lock settlement then transaction (fixed order), then validate both limits
CREATE FUNCTION chk_allocation() RETURNS trigger AS $$
DECLARE s_amt numeric; s_cur char(3); t_net numeric; t_cur char(3); s_used numeric; t_used numeric;
BEGIN
  SELECT settled_amount, currency_code INTO s_amt, s_cur FROM settlements  WHERE settlement_id  = NEW.settlement_id  FOR UPDATE;
  SELECT net_amount,     currency_code INTO t_net, t_cur FROM transactions WHERE transaction_id = NEW.transaction_id FOR UPDATE;
  IF s_cur <> t_cur THEN
    RAISE EXCEPTION 'currency mismatch: settlement is %, transaction is %', s_cur, t_cur;
  END IF;
  SELECT COALESCE(SUM(allocated_amount),0) INTO s_used FROM transaction_settlements
    WHERE settlement_id = NEW.settlement_id AND (transaction_id, settlement_id) <> (NEW.transaction_id, NEW.settlement_id);
  SELECT COALESCE(SUM(allocated_amount),0) INTO t_used FROM transaction_settlements
    WHERE transaction_id = NEW.transaction_id AND (transaction_id, settlement_id) <> (NEW.transaction_id, NEW.settlement_id);
  IF s_used + NEW.allocated_amount > s_amt THEN
    RAISE EXCEPTION 'allocation exceeds settlement: % + % > %', s_used, NEW.allocated_amount, s_amt;
  END IF;
  IF t_used + NEW.allocated_amount > t_net THEN
    RAISE EXCEPTION 'allocation exceeds transaction net: % + % > %', t_used, NEW.allocated_amount, t_net;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_allocation BEFORE INSERT OR UPDATE ON transaction_settlements
  FOR EACH ROW EXECUTE FUNCTION chk_allocation();

-- Gap G3: parents cannot shrink below money already allocated
CREATE FUNCTION guard_net_update() RETURNS trigger AS $$
DECLARE used numeric;
BEGIN
  SELECT COALESCE(SUM(allocated_amount),0) INTO used FROM transaction_settlements WHERE transaction_id = NEW.transaction_id;
  IF NEW.net_amount < used THEN
    RAISE EXCEPTION 'net_amount % is below already allocated %', NEW.net_amount, used;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_net BEFORE UPDATE OF net_amount ON transactions
  FOR EACH ROW EXECUTE FUNCTION guard_net_update();

CREATE FUNCTION guard_settled_update() RETURNS trigger AS $$
DECLARE used numeric;
BEGIN
  SELECT COALESCE(SUM(allocated_amount),0) INTO used FROM transaction_settlements WHERE settlement_id = NEW.settlement_id;
  IF NEW.settled_amount < used THEN
    RAISE EXCEPTION 'settled_amount % is below already allocated %', NEW.settled_amount, used;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_settled BEFORE UPDATE OF settled_amount ON settlements
  FOR EACH ROW EXECUTE FUNCTION guard_settled_update();

-- ---------- Derived STI-style read model ----------
CREATE MATERIALIZED VIEW mv_transactions_flat AS
SELECT t.transaction_id, t.transaction_type, t.event_date, t.gross_amount, t.fee_amount, t.tax_withheld,
       t.net_amount, t.currency_code, t.status,
       c.client, c.category, d.product, d.quantity, r.work_id, r.rights_type,
       s.plan, g.grantor, b.item_received, p.platform
FROM transactions t
LEFT JOIN commission_detail c        ON c.transaction_id = t.transaction_id
LEFT JOIN direct_sale_detail d       ON d.transaction_id = t.transaction_id
LEFT JOIN royalty_detail r           ON r.transaction_id = t.transaction_id
LEFT JOIN subscription_detail s      ON s.transaction_id = t.transaction_id
LEFT JOIN grant_detail g             ON g.transaction_id = t.transaction_id
LEFT JOIN barter_detail b            ON b.transaction_id = t.transaction_id
LEFT JOIN platform_payout_detail p   ON p.transaction_id = t.transaction_id;
CREATE UNIQUE INDEX uq_mv_flat ON mv_transactions_flat (transaction_id);

-- ---------- Sample data (core + subtype inserted in ONE statement each) ----------
INSERT INTO counterparties (name) VALUES ('Meera Gallery'), ('Kala Prints'), ('Patreon-style Platform');
INSERT INTO channels (name) VALUES ('Direct'), ('Marketplace'), ('Platform');

WITH tx AS (INSERT INTO transactions (transaction_type, event_date, gross_amount, fee_amount, tax_withheld, net_amount, currency_code, status, counterparty_id, channel_id)
  VALUES ('commission','2026-09-12',25000,2500,0,22500,'INR','paid',1,1) RETURNING transaction_id)
INSERT INTO commission_detail (transaction_id, client, category, milestones, delivery_date)
  SELECT transaction_id,'Meera Gallery','illustration',3,'2026-10-30' FROM tx;

WITH tx AS (INSERT INTO transactions (transaction_type, event_date, gross_amount, fee_amount, tax_withheld, net_amount, currency_code, status, counterparty_id, channel_id)
  VALUES ('direct_sale','2026-09-20',8000,1000,0,7000,'INR','paid',2,2) RETURNING transaction_id)
INSERT INTO direct_sale_detail (transaction_id, product, sale_channel, quantity, fulfilment)
  SELECT transaction_id,'Mandala print set','Marketplace',4,'delivered' FROM tx;

WITH tx AS (INSERT INTO transactions (transaction_type, event_date, gross_amount, fee_amount, tax_withheld, net_amount, currency_code, status)
  VALUES ('royalty','2026-10-02',300,30,15,255,'USD','paid') RETURNING transaction_id)
INSERT INTO royalty_detail (transaction_id, work_id, rights_type, period, rate_basis)
  SELECT transaction_id,'WORK-017','print','2026-Q3','percent of net' FROM tx;

WITH tx AS (INSERT INTO transactions (transaction_type, event_date, gross_amount, fee_amount, tax_withheld, net_amount, currency_code, status, counterparty_id, channel_id)
  VALUES ('subscription','2026-10-05',1200,120,0,1080,'INR','paid',3,3) RETURNING transaction_id)
INSERT INTO subscription_detail (transaction_id, plan, billing_period, subscriber_ref)
  SELECT transaction_id,'Patron tier 2','monthly','SUB-8841' FROM tx;

WITH tx AS (INSERT INTO transactions (transaction_type, event_date, gross_amount, fee_amount, tax_withheld, net_amount, currency_code, status)
  VALUES ('grant','2026-10-15',2000,0,0,2000,'EUR','pending') RETURNING transaction_id)
INSERT INTO grant_detail (transaction_id, grantor, programme, award_ref, deadline)
  SELECT transaction_id,'Arts Council','Emerging Artists','AC-2026-114','2026-12-31' FROM tx;

WITH tx AS (INSERT INTO transactions (transaction_type, event_date, gross_amount, fee_amount, tax_withheld, net_amount, currency_code, status)
  VALUES ('barter','2026-10-18',3000,0,0,3000,'INR','paid') RETURNING transaction_id)
INSERT INTO barter_detail (transaction_id, item_received, fair_value, exchange_ref)
  SELECT transaction_id,'Studio lighting kit',3000,'BX-221' FROM tx;

INSERT INTO settlements (destination_account, settled_amount, currency_code, reconciliation_status)
  VALUES ('HDFC-XXXX1234', 30000, 'INR', 'open');
INSERT INTO transaction_settlements (transaction_id, settlement_id, allocated_amount) VALUES (1, 1, 22500), (2, 1, 7000);

REFRESH MATERIALIZED VIEW mv_transactions_flat;
