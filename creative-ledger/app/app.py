"""Creative Ledger - demo front end for the hybrid PostgreSQL schema.

Run:  DATABASE_URL="dbname=creative" python app/app.py
"""
import os
from decimal import Decimal, InvalidOperation

import psycopg2
import psycopg2.extras
from psycopg2 import sql
from flask import Flask, flash, g, redirect, render_template, request, url_for

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "dev-only-change-me")
DSN = os.environ.get("DATABASE_URL", "dbname=creative")

# Subtype form definitions: (column, label, kind). kind is text/int/num/date or a list of options.
SUBTYPES = {
    "commission": [("client", "Client", "text"), ("category", "Category", "text"),
                   ("milestones", "Milestones", "int"), ("delivery_date", "Delivery date", "date")],
    "direct_sale": [("product", "Product", "text"), ("sale_channel", "Sale channel", "text"),
                    ("quantity", "Quantity", "int"),
                    ("fulfilment", "Fulfilment", ["pending", "shipped", "delivered"])],
    "royalty": [("work_id", "Work ID", "text"),
                ("rights_type", "Rights type", ["print", "digital", "licensing", "performance"]),
                ("period", "Period", "text"), ("rate_basis", "Rate basis", "text")],
    "subscription": [("plan", "Plan", "text"),
                     ("billing_period", "Billing period", ["monthly", "quarterly", "annual"]),
                     ("subscriber_ref", "Subscriber ref", "text")],
    "grant": [("grantor", "Grantor", "text"), ("programme", "Programme", "text"),
              ("award_ref", "Award ref", "text"), ("deadline", "Deadline", "date")],
    "barter": [("item_received", "Item received", "text"), ("fair_value", "Fair value", "num"),
               ("exchange_ref", "Exchange ref", "text")],
    "platform_payout": [("platform", "Platform", "text"), ("payout_ref", "Payout ref", "text"),
                        ("batch_ref", "Batch ref", "text")],
}
CURRENCIES = ["INR", "USD", "EUR"]


# ---------- helpers ----------
def db():
    if "conn" not in g:
        g.conn = psycopg2.connect(DSN)
    return g.conn


@app.teardown_appcontext
def close_db(_exc):
    conn = g.pop("conn", None)
    if conn is not None:
        conn.close()


def rows(query, args=None):
    conn = db()
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(query, args)
        result = cur.fetchall()
    conn.rollback()
    return result


def clean(err):
    """First line of a database or validation error, for display."""
    text = str(err).strip()
    return text.splitlines()[0] if text else err.__class__.__name__


def write(statement, args, ok_message):
    conn = db()
    try:
        with conn.cursor() as cur:
            cur.execute(statement, args)
        conn.commit()
        flash(ok_message, "ok")
    except psycopg2.Error as err:
        conn.rollback()
        flash(clean(err), "err")


def convert(value, kind):
    if kind == "int":
        return int(value)
    if kind == "num":
        return Decimal(value)
    return value


def insert_transaction(cur, ttype, core, detail):
    """Insert the core row and its subtype row in the same transaction."""
    gross, fee, tax = core["gross"], core["fee"], core["tax"]
    cur.execute(
        """INSERT INTO transactions (transaction_type, gross_amount, fee_amount, tax_withheld,
                                     net_amount, currency_code, counterparty_id, channel_id)
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s) RETURNING transaction_id""",
        (ttype, gross, fee, tax, gross - fee - tax, core["currency"],
         core.get("counterparty_id"), core.get("channel_id")))
    tid = cur.fetchone()[0]
    cols = list(detail)
    cur.execute(
        sql.SQL("INSERT INTO {} (transaction_id, {}) VALUES (%s, {})").format(
            sql.Identifier(ttype + "_detail"),
            sql.SQL(", ").join(map(sql.Identifier, cols)),
            sql.SQL(", ").join([sql.Placeholder()] * len(cols))),
        [tid, *detail.values()])
    return tid


# ---------- pages ----------
@app.route("/")
def index():
    monthly = rows("""SELECT to_char(date_trunc('month', event_date), 'YYYY-MM') AS month,
                             currency_code, transaction_type, SUM(net_amount) AS net, COUNT(*) AS n
                      FROM transactions GROUP BY 1, 2, 3 ORDER BY 1 DESC, 2, 3""")
    recent = rows("SELECT * FROM mv_transactions_flat ORDER BY event_date DESC LIMIT 15")
    return render_template("index.html", monthly=monthly, recent=recent)


@app.post("/refresh")
def refresh():
    write("REFRESH MATERIALIZED VIEW mv_transactions_flat", None, "Read model refreshed.")
    return redirect(url_for("index"))


@app.route("/add", methods=["GET", "POST"])
def add():
    conn = db()
    if request.method == "POST":
        ttype = request.form.get("transaction_type", "")
        try:
            if ttype not in SUBTYPES:
                raise ValueError("Unknown transaction type")
            core = {
                "gross": Decimal(request.form.get("gross") or 0),
                "fee": Decimal(request.form.get("fee") or 0),
                "tax": Decimal(request.form.get("tax") or 0),
                "currency": request.form.get("currency", "INR"),
                "counterparty_id": request.form.get("counterparty_id") or None,
                "channel_id": request.form.get("channel_id") or None,
            }
            detail = {col: convert(request.form[col], kind if isinstance(kind, str) else "text")
                      for col, _label, kind in SUBTYPES[ttype]}
            with conn.cursor() as cur:
                tid = insert_transaction(cur, ttype, core, detail)
            conn.commit()
            flash(f"Saved transaction #{tid} ({ttype}).", "ok")
            return redirect(url_for("index"))
        except (psycopg2.Error, ValueError, InvalidOperation, KeyError) as err:
            conn.rollback()
            flash(clean(err), "err")
    return render_template("add.html", subtypes=SUBTYPES, currencies=CURRENCIES,
                           counterparties=rows("SELECT * FROM counterparties ORDER BY 1"),
                           channels=rows("SELECT * FROM channels ORDER BY 1"))


@app.route("/settlements")
def settlements():
    return render_template(
        "settlements.html", currencies=CURRENCIES,
        settlements=rows("""SELECT s.*, COALESCE(SUM(a.allocated_amount), 0) AS allocated
                            FROM settlements s
                            LEFT JOIN transaction_settlements a ON a.settlement_id = s.settlement_id
                            GROUP BY s.settlement_id ORDER BY s.settlement_id DESC"""),
        txs=rows("""SELECT transaction_id, transaction_type, net_amount, currency_code
                    FROM transactions ORDER BY transaction_id DESC LIMIT 50"""),
        allocations=rows("SELECT * FROM transaction_settlements ORDER BY settlement_id DESC, transaction_id"))


@app.post("/settlements/new")
def settlement_new():
    write("""INSERT INTO settlements (destination_account, settled_amount, currency_code)
             VALUES (%s, %s, %s)""",
          (request.form["destination"], request.form["amount"], request.form["currency"]),
          "Settlement created.")
    return redirect(url_for("settlements"))


@app.post("/settlements/allocate")
def settlement_allocate():
    write("""INSERT INTO transaction_settlements (transaction_id, settlement_id, allocated_amount)
             VALUES (%s, %s, %s)""",
          (request.form["transaction_id"], request.form["settlement_id"], request.form["amount"]),
          "Allocation saved.")
    return redirect(url_for("settlements"))


# ---------- integrity demo: every test runs inside a transaction that is rolled back ----------
def make_tx(cur, ttype="commission", gross="1000.00", currency="INR"):
    detail = {"client": "Test client", "category": "illustration", "milestones": 2,
              "delivery_date": "2026-12-31"}
    core = {"gross": Decimal(gross), "fee": Decimal(0), "tax": Decimal(0), "currency": currency}
    return insert_transaction(cur, ttype, core, detail)


def make_settlement(cur, amount="1000.00", currency="INR"):
    cur.execute("""INSERT INTO settlements (destination_account, settled_amount, currency_code)
                   VALUES ('TEST-ACCOUNT', %s, %s) RETURNING settlement_id""", (amount, currency))
    return cur.fetchone()[0]


def allocate(cur, tid, sid, amount):
    cur.execute("""INSERT INTO transaction_settlements (transaction_id, settlement_id, allocated_amount)
                   VALUES (%s, %s, %s)""", (tid, sid, amount))


RAW_TX = """INSERT INTO transactions (transaction_type, gross_amount, fee_amount, tax_withheld,
                                      net_amount, currency_code, metadata)
            VALUES (%s, 1000, 100, 0, %s, %s, %s)"""


def t_net(cur):
    cur.execute(RAW_TX, ("commission", 999, "INR", "{}"))


def t_type(cur):
    cur.execute(RAW_TX, ("gift", 900, "INR", "{}"))


def t_currency(cur):
    cur.execute(RAW_TX, ("commission", 900, "inr", "{}"))


def t_meta(cur):
    cur.execute(RAW_TX, ("commission", 900, "INR", '{"gross_amount": 1}'))


def t_wrong_subtype(cur):
    tid = make_tx(cur)
    cur.execute("""INSERT INTO royalty_detail (transaction_id, work_id, rights_type, period, rate_basis)
                   VALUES (%s, 'W1', 'print', '2026-Q3', 'flat')""", (tid,))


def t_orphan(cur):
    cur.execute(RAW_TX, ("commission", 900, "INR", "{}"))
    cur.execute("SET CONSTRAINTS ALL IMMEDIATE")


def t_custom_field(cur):
    tid = make_tx(cur)
    cur.execute("""INSERT INTO custom_field_def (field_name, transaction_type, data_type)
                   VALUES ('mood', 'royalty', 'text') RETURNING field_id""")
    fid = cur.fetchone()[0]
    cur.execute("""INSERT INTO custom_field_value (field_id, transaction_id, transaction_type, text_value)
                   VALUES (%s, %s, 'commission', 'calm')""", (fid, tid))


def t_overallocate(cur):
    tid, sid = make_tx(cur), make_settlement(cur)
    allocate(cur, tid, sid, "600.00")
    tid2 = make_tx(cur)
    allocate(cur, tid2, sid, "600.00")


def t_currency_mismatch(cur):
    allocate(cur, make_tx(cur, currency="INR"), make_settlement(cur, currency="USD"), "100.00")


def t_shrink_net(cur):
    tid, sid = make_tx(cur), make_settlement(cur)
    allocate(cur, tid, sid, "850.00")
    cur.execute("UPDATE transactions SET gross_amount = 100, net_amount = 100 WHERE transaction_id = %s", (tid,))


def t_quantity(cur):
    detail = {"product": "Print", "sale_channel": "Direct", "quantity": 0, "fulfilment": "pending"}
    insert_transaction(cur, "direct_sale", {"gross": Decimal(500), "fee": Decimal(0), "tax": Decimal(0), "currency": "INR"}, detail)


def t_required(cur):
    detail = {"client": None, "category": "illustration", "milestones": 1, "delivery_date": "2026-12-31"}
    insert_transaction(cur, "commission", {"gross": Decimal(500), "fee": Decimal(0), "tax": Decimal(0), "currency": "INR"}, detail)


def t_enum(cur):
    detail = {"product": "Print", "sale_channel": "Direct", "quantity": 1, "fulfilment": "lost"}
    insert_transaction(cur, "direct_sale", {"gross": Decimal(500), "fee": Decimal(0), "tax": Decimal(0), "currency": "INR"}, detail)


def t_text_numeric(cur):
    detail = {"item_received": "Lamp", "fair_value": "abc", "exchange_ref": "BX-1"}
    insert_transaction(cur, "barter", {"gross": Decimal(500), "fee": Decimal(0), "tax": Decimal(0), "currency": "INR"}, detail)


def t_orphan_detail(cur):
    cur.execute("""INSERT INTO royalty_detail (transaction_id, work_id, rights_type, period, rate_basis)
                   VALUES (999999999, 'W1', 'print', '2026-Q3', 'flat')""")


# Suite A-G matches Table VII of the paper; "Gap" tests match Table III (G1-G4).
TESTS = [
    ("Suite A: net amount does not equal gross - fee - tax", t_net),
    ("Suite B: quantity of zero on a direct sale", t_quantity),
    ("Suite C: required attribute missing (commission without client)", t_required),
    ("Suite D: royalty row attached to a commission (attribute of another type)", t_wrong_subtype),
    ("Suite E: invalid enumeration value (fulfilment = lost)", t_enum),
    ("Suite F: text in a numeric attribute (fair value = abc)", t_text_numeric),
    ("Suite G: detail row with no parent transaction (orphan)", t_orphan_detail),
    ("Core: unknown transaction type", t_type),
    ("Core: lower-case currency code", t_currency),
    ("Core: protected core key hidden in metadata", t_meta),
    ("Gap G1: custom field defined for another type", t_custom_field),
    ("Gap G2: transaction without a subtype row", t_orphan),
    ("Gap G3: net amount edited below allocated money", t_shrink_net),
    ("Gap G4 (limit check): allocations exceeding a settlement", t_overallocate),
    ("Settlement and transaction in different currencies", t_currency_mismatch),
]


@app.route("/integrity", methods=["GET", "POST"])
def integrity():
    results = None
    if request.method == "POST":
        results = []
        conn = db()
        for label, test in TESTS:
            try:
                with conn.cursor() as cur:
                    test(cur)
                results.append((label, False, "Accepted. The database did not stop this input."))
            except psycopg2.Error as err:
                results.append((label, True, clean(err)))
            finally:
                conn.rollback()
    return render_template("integrity.html", results=results)


@app.route("/results")
def results():
    return render_template("results.html")


if __name__ == "__main__":
    app.run(debug=True)
