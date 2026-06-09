#!/usr/bin/env python3
from __future__ import annotations

import argparse
import getpass
import json
import os
import ssl
from pathlib import Path

DEFAULT_DB_PASSWORD = "DB23ee###12345"

CREATE_KEEP = """
create table bank_pdf_keep_duplicates (
  statement_copy_id number primary key,
  statement_id      number not null,
  copy_role         varchar2(30),
  account_no        varchar2(30),
  statement_month   date,
  pdf_document      blob,
  mime_type         varchar2(30),
  file_name         varchar2(256)
)
lob (pdf_document) store as securefile (keep_duplicates nocompress nocache logging)
"""

CREATE_DEDUP = """
create table bank_pdf_deduplicate (
  statement_copy_id number primary key,
  statement_id      number not null,
  copy_role         varchar2(30),
  account_no        varchar2(30),
  statement_month   date,
  pdf_document      blob,
  mime_type         varchar2(30),
  file_name         varchar2(256)
)
lob (pdf_document) store as securefile (deduplicate nocompress nocache logging)
"""

INSERT_TEMPLATE = """
insert into {table_name} (
  statement_copy_id, statement_id, copy_role, account_no, statement_month,
  pdf_document, mime_type, file_name
) values (
  :statement_copy_id, :statement_id, :copy_role, :account_no,
  to_date(:statement_month, 'YYYY-MM-DD'), :pdf_document, :mime_type, :file_name
)
"""

RATIO_SQL = """
with lob_segments as (
  select l.table_name, s.bytes
  from user_lobs l
  join user_segments s on s.segment_name = l.segment_name
  where l.table_name in ('BANK_PDF_KEEP_DUPLICATES', 'BANK_PDF_DEDUPLICATE')
  and l.column_name = 'PDF_DOCUMENT'
),
summary as (
  select
    max(case when table_name = 'BANK_PDF_KEEP_DUPLICATES' then bytes end) keep_bytes,
    max(case when table_name = 'BANK_PDF_DEDUPLICATE' then bytes end) dedup_bytes
  from lob_segments
)
select round(keep_bytes / 1024 / 1024, 2),
       round(dedup_bytes / 1024 / 1024, 2),
       round(keep_bytes / nullif(dedup_bytes, 0), 2)
from summary
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-dir", default="generated_bank_pdfs")
    parser.add_argument("--dsn", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--password", default=os.getenv("ADB_PASSWORD", DEFAULT_DB_PASSWORD))
    parser.add_argument("--wallet-dir")
    parser.add_argument("--wallet-password", default=os.getenv("ADB_WALLET_PASSWORD"))
    parser.add_argument("--tls-insecure-skip-verify", action="store_true")
    parser.add_argument("--recreate", action="store_true")
    parser.add_argument("--batch-size", type=int, default=100)
    return parser.parse_args()


def import_oracledb():
    try:
        import oracledb  # type: ignore
    except ModuleNotFoundError as exc:
        raise SystemExit("Missing dependency. Install it with: python3 -m pip install oracledb") from exc
    return oracledb


def connect(oracledb, args: argparse.Namespace):
    kwargs = {
        "user": args.user,
        "password": args.password or getpass.getpass(f"Password for {args.user}: "),
        "dsn": args.dsn,
    }
    if args.wallet_dir:
        kwargs["config_dir"] = args.wallet_dir
        kwargs["wallet_location"] = args.wallet_dir
    if args.wallet_password:
        kwargs["wallet_password"] = args.wallet_password
    if args.tls_insecure_skip_verify:
        kwargs["ssl_context"] = ssl._create_unverified_context()
        kwargs["ssl_server_dn_match"] = False
    print("Connecting to database...", flush=True)
    return oracledb.connect(**kwargs)


def ignore_missing(cursor, sql: str) -> None:
    try:
        cursor.execute(sql)
    except Exception as exc:
        if "ORA-00942" not in str(exc):
            raise


def recreate(cursor) -> None:
    ignore_missing(cursor, "drop table bank_pdf_keep_duplicates purge")
    ignore_missing(cursor, "drop table bank_pdf_deduplicate purge")
    cursor.execute(CREATE_KEEP)
    cursor.execute(CREATE_DEDUP)


def load_table(cursor, table_name: str, input_dir: Path, manifest: list[dict], batch_size: int) -> int:
    sql = INSERT_TEMPLATE.format(table_name=table_name)
    batch = []
    inserted = 0
    for item in manifest:
        row = {
            "statement_copy_id": item["statement_copy_id"],
            "statement_id": item["statement_id"],
            "copy_role": item["copy_role"],
            "account_no": item["account_no"],
            "statement_month": item["statement_month"],
            "mime_type": item["mime_type"],
            "file_name": item["file_name"],
        }
        row["pdf_document"] = (input_dir / item["file_name"]).read_bytes()
        batch.append(row)
        if len(batch) >= batch_size:
            cursor.executemany(sql, batch)
            inserted += len(batch)
            print(f"{table_name}: loaded {inserted} rows...", flush=True)
            batch.clear()
    if batch:
        cursor.executemany(sql, batch)
        inserted += len(batch)
    return inserted


def print_summary(cursor) -> None:
    cursor.execute("""
        select 'BANK_PDF_KEEP_DUPLICATES', count(*), round(avg(dbms_lob.getlength(pdf_document)) / 1024, 2)
        from bank_pdf_keep_duplicates
        union all
        select 'BANK_PDF_DEDUPLICATE', count(*), round(avg(dbms_lob.getlength(pdf_document)) / 1024, 2)
        from bank_pdf_deduplicate
    """)
    for table_name, row_count, avg_kb in cursor:
        print(f"{table_name}: rows={row_count}, avg_pdf_kb={avg_kb}")
    cursor.execute(RATIO_SQL)
    keep_mb, dedup_mb, ratio = cursor.fetchone()
    print(f"KEEP_DUPLICATES allocated MB: {keep_mb}")
    print(f"DEDUPLICATE allocated MB: {dedup_mb}")
    print(f"Actual dedup ratio: {ratio}")


def main() -> None:
    args = parse_args()
    input_dir = Path(args.input_dir)
    manifest = json.loads((input_dir / "manifest.json").read_text(encoding="utf-8"))
    oracledb = import_oracledb()
    with connect(oracledb, args) as con:
        with con.cursor() as cur:
            if args.recreate:
                recreate(cur)
            keep = load_table(cur, "bank_pdf_keep_duplicates", input_dir, manifest, args.batch_size)
            dedup = load_table(cur, "bank_pdf_deduplicate", input_dir, manifest, args.batch_size)
            con.commit()
            print(f"Loaded {keep} rows into BANK_PDF_KEEP_DUPLICATES")
            print(f"Loaded {dedup} rows into BANK_PDF_DEDUPLICATE")
            print_summary(cur)


if __name__ == "__main__":
    main()
