# Creative Ledger

A hybrid PostgreSQL schema for heterogeneous income in small-scale creative enterprises (commissions, direct sales, royalties, subscriptions, grants, barter, platform payouts), with a small Flask front end that demonstrates it.

Based on the Review 1 paper: *A Domain-Specific Relational Schema Framework for Heterogeneous Transaction Modelling in Small-Scale Creative Enterprises*.

## What is in the repo

| Path | Purpose |
|---|---|
| `sql/schema.sql` | Full schema, triggers, read model and sample data |
| `app/app.py` | Flask application (routes, validation, integrity tests) |
| `app/templates/` | Dashboard, add transaction, settlements, integrity tests, benchmark results |
| `tests/concurrency_test.py` | Two simultaneous sessions over-allocating one settlement (gap G4) |
| `docs/` | Diagrams: ER, DFD, use case, class, sequence, architecture (to be added) |

## Design in one paragraph

A shared `transactions` core holds the thirteen common columns. Seven Class Table Inheritance tables hold subtype fields and are tied to the core by a composite foreign key on `(transaction_id, transaction_type)`, so a royalty row cannot be attached to a commission. A constrained JSONB column holds rare metadata, an EAV-lite pair handles runtime-defined fields, settlements are decoupled through a many-to-many allocation table, and a materialized view provides a flat read model.

## Setup

Requirements: PostgreSQL 14 or later, Python 3.10 or later.

```bash
createdb creative
psql -v ON_ERROR_STOP=1 -d creative -f sql/schema.sql

python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt

export DATABASE_URL="dbname=creative"   # add user/password/host if needed
python app/app.py
```

Open http://127.0.0.1:5000.

## Screens

- **Dashboard:** monthly net income by type and currency, plus the latest rows from `mv_transactions_flat`.
- **Add transaction:** one form that changes with the transaction type; the core row and subtype row are inserted in one transaction.
- **Settlements:** create settlements and allocate transactions to them. Over-allocation and currency mismatches are rejected by the database.
- **Integrity tests:** runs 15 invalid inputs (Suite A-G from the paper's Table VII, the core rules, and gaps G1-G4) against the database and shows which constraint stopped each one. Every test is rolled back.
- **Benchmark results:** CTI, STI and EAV comparison at 1M transactions from the paper.

## Integrity gaps fixed (from the paper)

| Gap | Problem | Fix |
|---|---|---|
| G1 | Custom field defined for one type attached to another | Type tag and composite foreign keys |
| G2 | Transaction with no subtype row | Deferred constraint trigger |
| G3 | `net_amount` edited below allocated money | Parent-update guard triggers |
| G4 | Two sessions over-allocated a settlement | `FOR UPDATE` row locks in a fixed order |

## Concurrency test (gap G4)

With the app's database running and `DATABASE_URL` set:

```bash
python tests/concurrency_test.py
```

Session A holds an allocation of 600 open for two seconds. Session B tries another 600 against the same 1,000 settlement meanwhile. Expected output: A accepted, B rejected after waiting, total 600, `PASS`.

## Git workflow

```bash
git init
git add .
git commit -m "Initial commit: schema, Flask demo, README"
git branch -M main
git remote add origin <your-repo-url>
git push -u origin main
```
