"""Gap G4: two sessions allocate against the same settlement at the same time.

Session A inserts an allocation of 600 and holds its transaction open for 2 seconds.
Session B tries to allocate another 600 against the same 1,000 settlement while A is open.
With the FOR UPDATE locks in chk_allocation(), B must wait for A and then be rejected.
Expected: exactly one allocation succeeds and the total never exceeds 1,000.

Run:  DATABASE_URL="dbname=creative user=postgres password=... host=localhost" python tests/concurrency_test.py
"""
import os
import threading
import time

import psycopg2

DSN = os.environ.get("DATABASE_URL", "dbname=creative")
results = {}


def make_tx(cur):
    cur.execute("""WITH tx AS (INSERT INTO transactions (transaction_type, gross_amount, net_amount, currency_code)
                               VALUES ('commission', 1000, 1000, 'INR') RETURNING transaction_id)
                   INSERT INTO commission_detail (transaction_id, client, category, milestones, delivery_date)
                   SELECT transaction_id, 'Concurrency test', 'test', 1, '2026-12-31' FROM tx
                   RETURNING transaction_id""")
    return cur.fetchone()[0]


def session(name, tid, sid, hold, delay):
    time.sleep(delay)
    conn = psycopg2.connect(DSN)
    start = time.time()
    try:
        with conn.cursor() as cur:
            cur.execute("""INSERT INTO transaction_settlements (transaction_id, settlement_id, allocated_amount)
                           VALUES (%s, %s, 600)""", (tid, sid))
            time.sleep(hold)          # keep the transaction open so the sessions overlap
        conn.commit()
        results[name] = ("ACCEPTED", time.time() - start)
    except psycopg2.Error as err:
        conn.rollback()
        results[name] = ("REJECTED: " + str(err).splitlines()[0], time.time() - start)
    finally:
        conn.close()


setup = psycopg2.connect(DSN)
with setup, setup.cursor() as cur:
    tid_a, tid_b = make_tx(cur), make_tx(cur)
    cur.execute("""INSERT INTO settlements (destination_account, settled_amount, currency_code)
                   VALUES ('CONCURRENCY-TEST', 1000, 'INR') RETURNING settlement_id""")
    sid = cur.fetchone()[0]

a = threading.Thread(target=session, args=("Session A", tid_a, sid, 2.0, 0.0))
b = threading.Thread(target=session, args=("Session B", tid_b, sid, 0.0, 0.5))
a.start(); b.start(); a.join(); b.join()

with setup, setup.cursor() as cur:
    cur.execute("SELECT COALESCE(SUM(allocated_amount), 0) FROM transaction_settlements WHERE settlement_id = %s", (sid,))
    total = cur.fetchone()[0]
    # clean up everything this test created (details and allocations cascade)
    cur.execute("DELETE FROM settlements WHERE settlement_id = %s", (sid,))
    cur.execute("DELETE FROM transactions WHERE transaction_id IN (%s, %s)", (tid_a, tid_b))
setup.close()

for name in sorted(results):
    outcome, seconds = results[name]
    print(f"{name}: {outcome}  (took {seconds:.1f}s)")
print(f"Total allocated against the 1000.00 settlement: {total}")
accepted = sum(1 for o, _ in results.values() if o == "ACCEPTED")
print("PASS" if accepted == 1 and total <= 1000 else "FAIL")
