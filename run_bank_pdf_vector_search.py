#!/usr/bin/env python3
from __future__ import annotations

import argparse
import getpass
import os
import re
import ssl

DEFAULT_ADB_DSN = """(description=
  (retry_count=20)
  (retry_delay=3)
  (address=(protocol=tcps)(port=1521)(host=<adb-hostname>))
  (connect_data=(service_name=<adb-service-name>))
  (security=(ssl_server_dn_match=yes))
)"""
DEFAULT_DB_USER = "YOUR_SCHEMA"
DEFAULT_DB_PASSWORD = ""

SEARCH_SQL = """
with query_vector as (
  select vector_embedding({model_name} using :query_text as data) as v
  from dual
),
ranked as (
  select c.statement_id,
         c.copy_role,
         c.account_no,
         c.statement_month,
         c.file_name,
         c.chunk_no,
         vector_distance(e.embedding, q.v, cosine) as distance,
         dbms_lob.substr(c.chunk_text, 4000, 1) as snippet
  from   BANK_PDF_VECTOR_CHUNKS c
  join   BANK_PDF_VECTOR_EMBEDDINGS e
    on   e.chunk_id = c.chunk_id
  cross join query_vector q
  order  by vector_distance(e.embedding, q.v, cosine)
  fetch first {top_k} rows only
)
select statement_id,
       copy_role,
       account_no,
       to_char(statement_month, 'YYYY-MM-DD') as statement_month,
       file_name,
       chunk_no,
       round(distance, 6) as distance,
       snippet
from ranked
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run semantic search over BANK_PDF_DEDUPLICATE PDF chunks.")
    parser.add_argument("query", help="Natural-language search text.")
    parser.add_argument(
        "--dsn",
        default=os.getenv("ADB_DSN", DEFAULT_ADB_DSN),
        help="ADB connect descriptor. Defaults to ADB_DSN or the wallet-less ADB TCPS descriptor.",
    )
    parser.add_argument("--user", default=os.getenv("ADB_USER", DEFAULT_DB_USER))
    parser.add_argument("--password", default=os.getenv("ADB_PASSWORD", DEFAULT_DB_PASSWORD))
    parser.add_argument("--wallet-dir")
    parser.add_argument("--wallet-password", default=os.getenv("ADB_WALLET_PASSWORD"))
    tls_group = parser.add_mutually_exclusive_group()
    tls_group.add_argument(
        "--tls-insecure-skip-verify",
        dest="tls_insecure_skip_verify",
        action="store_true",
        default=True,
        help="Skip TLS certificate verification. Default for this wallet-less demo connection.",
    )
    tls_group.add_argument(
        "--tls-verify",
        dest="tls_insecure_skip_verify",
        action="store_false",
        help="Enable strict TLS certificate verification.",
    )
    parser.add_argument("--model-name", default="all_MiniLM_L12_v2")
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--snippet-chars", type=int, default=500)
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
    return oracledb.connect(**kwargs)


def validate_sql_name(name: str) -> str:
    if not name.replace("_", "").replace("$", "").replace("#", "").isalnum():
        raise SystemExit(f"Unsafe model name: {name}")
    return name


def snippet_terms(query: str) -> list[str]:
    query_terms = [term.upper() for term in re.findall(r"[A-Za-z][A-Za-z0-9_]{2,}", query)]
    demo_terms = [
        "FRAUD",
        "PHISHING",
        "SUSPICIOUS",
        "SECURITY",
        "CARD LOCK",
        "PASSWORD SAFETY",
        "DISPUTE",
        "BILLING ERROR",
        "CLAIM",
    ]
    seen = set()
    terms = []
    for term in demo_terms + query_terms:
        if term not in seen:
            terms.append(term)
            seen.add(term)
    return terms


def relevant_snippet(text: str, query: str, width: int) -> str:
    compact = " ".join(str(text).split())
    upper = compact.upper()
    hit = -1
    for term in snippet_terms(query):
        hit = upper.find(term)
        if hit >= 0:
            break
    if hit < 0:
        return compact[:width]
    start = max(0, hit - width // 3)
    end = min(len(compact), start + width)
    if end - start < width:
        start = max(0, end - width)
    prefix = "... " if start > 0 else ""
    suffix = " ..." if end < len(compact) else ""
    return prefix + compact[start:end] + suffix


def main() -> None:
    args = parse_args()
    model_name = validate_sql_name(args.model_name)
    top_k = max(1, min(args.top_k, 50))
    snippet_chars = max(120, min(args.snippet_chars, 1000))
    oracledb = import_oracledb()
    sql = SEARCH_SQL.format(model_name=model_name, top_k=top_k, snippet_chars=snippet_chars)
    with connect(oracledb, args) as con:
        with con.cursor() as cur:
            cur.execute(sql, {"query_text": args.query})
            rows = cur.fetchall()

    print(f"\nQuery: {args.query}")
    print(f"Model: {model_name}")
    print(f"Top matches: {len(rows)}\n")
    for i, row in enumerate(rows, start=1):
        statement_id, copy_role, account_no, statement_month, file_name, chunk_no, distance, snippet = row
        preview = relevant_snippet(str(snippet), args.query, snippet_chars)
        print(f"{i}. statement={statement_id} role={copy_role} chunk={chunk_no} distance={distance}")
        print(f"   account={account_no} month={statement_month} file={file_name}")
        print(f"   {preview}")
        print()


if __name__ == "__main__":
    main()
