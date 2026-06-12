#!/usr/bin/env python3
from __future__ import annotations

import argparse
import io
import getpass
import logging
import os
import re
import ssl
import zlib

DEFAULT_ADB_DSN = """(description=
  (retry_count=20)
  (retry_delay=3)
  (address=(protocol=tcps)(port=1521)(host=<adb-hostname>))
  (connect_data=(service_name=<adb-service-name>))
  (security=(ssl_server_dn_match=yes))
)"""
DEFAULT_DB_USER = "YOUR_SCHEMA"
DEFAULT_DB_PASSWORD = ""

CREATE_CHUNKS = """
create table BANK_PDF_VECTOR_CHUNKS (
  chunk_id          number generated always as identity primary key,
  statement_copy_id number not null,
  statement_id      number not null,
  copy_role         varchar2(30),
  account_no        varchar2(30),
  statement_month   date,
  file_name         varchar2(256),
  chunk_no          number not null,
  chunk_text        clob not null,
  constraint bank_pdf_vec_chunk_uk unique (statement_copy_id, chunk_no)
)
"""

INSERT_CHUNK = """
insert into BANK_PDF_VECTOR_CHUNKS (
  statement_copy_id, statement_id, copy_role, account_no, statement_month,
  file_name, chunk_no, chunk_text
) values (
  :statement_copy_id, :statement_id, :copy_role, :account_no, :statement_month,
  :file_name, :chunk_no, :chunk_text
)
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract text from BANK_PDF_DEDUPLICATE PDF BLOBs and load chunks for Oracle AI Vector Search.",
    )
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
    parser.add_argument("--recreate", action="store_true")
    parser.add_argument("--limit", type=int, default=0, help="Optional max source PDF rows to process.")
    parser.add_argument("--chunk-chars", type=int, default=1800)
    parser.add_argument("--overlap-chars", type=int, default=200)
    parser.add_argument("--batch-size", type=int, default=100)
    return parser.parse_args()


def import_oracledb():
    try:
        import oracledb  # type: ignore
    except ModuleNotFoundError as exc:
        raise SystemExit("Missing dependency. Install it with: python3 -m pip install oracledb") from exc
    return oracledb


def import_pypdf():
    try:
        from pypdf import PdfReader  # type: ignore
    except ModuleNotFoundError:
        return None
    logging.getLogger("pypdf").setLevel(logging.ERROR)
    return PdfReader


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
    ignore_missing(cursor, "drop table BANK_PDF_VECTOR_EMBEDDINGS purge")
    ignore_missing(cursor, "drop table BANK_PDF_VECTOR_CHUNKS purge")
    cursor.execute(CREATE_CHUNKS)


def pdf_literal_unescape(value: bytes) -> str:
    out = bytearray()
    i = 0
    while i < len(value):
        ch = value[i]
        if ch != 0x5C:
            out.append(ch)
            i += 1
            continue
        i += 1
        if i >= len(value):
            break
        esc = value[i]
        mapping = {
            ord("n"): ord("\n"),
            ord("r"): ord("\r"),
            ord("t"): ord("\t"),
            ord("b"): ord("\b"),
            ord("f"): ord("\f"),
            ord("("): ord("("),
            ord(")"): ord(")"),
            ord("\\"): ord("\\"),
        }
        if esc in mapping:
            out.append(mapping[esc])
            i += 1
            continue
        out.append(esc)
        i += 1
    return out.decode("latin-1", errors="replace")


def iter_pdf_streams(pdf_bytes: bytes):
    for match in re.finditer(rb"(?P<dict><<.*?>>)\s*stream\r?\n(?P<data>.*?)\r?\nendstream", pdf_bytes, flags=re.DOTALL):
        stream_dict = match.group("dict")
        data = match.group("data")
        if b"/FlateDecode" in stream_dict:
            try:
                data = zlib.decompress(data)
            except zlib.error:
                continue
        yield data


def extract_text_operators(content: bytes) -> list[str]:
    texts = []

    for match in re.finditer(rb"\(((?:\\.|[^\\)])*)\)\s*Tj", content, flags=re.DOTALL):
        text = pdf_literal_unescape(match.group(1)).strip()
        if text:
            texts.append(text)

    for array_match in re.finditer(rb"\[(.*?)\]\s*TJ", content, flags=re.DOTALL):
        parts = []
        for text_match in re.finditer(rb"\(((?:\\.|[^\\)])*)\)", array_match.group(1), flags=re.DOTALL):
            part = pdf_literal_unescape(text_match.group(1))
            if part:
                parts.append(part)
        text = "".join(parts).strip()
        if text:
            texts.append(text)

    return texts


def extract_generated_pdf_text(pdf_bytes: bytes) -> str:
    """Best-effort text extraction for generated PDFs used in this demo."""
    texts = []
    for stream in iter_pdf_streams(pdf_bytes):
        texts.extend(extract_text_operators(stream))
    if not texts:
        texts = extract_text_operators(pdf_bytes)
    return "\n".join(texts)


def extract_plain_blob_text(pdf_bytes: bytes) -> str:
    text = pdf_bytes.decode("latin-1", errors="ignore")
    text = text.replace("\x00", "")
    text = re.sub(r"^%PDF-[^\n\r]*(\r?\n)?", "", text)
    text = text.replace("%%EOF", "")
    lines = [line.rstrip() for line in text.splitlines()]
    text = "\n".join(line for line in lines if line.strip())
    printable = sum(1 for ch in text if ch.isprintable() or ch in "\r\n\t")
    if not text or printable / max(len(text), 1) < 0.85:
        return ""
    return text.strip()


def extract_pdf_text(pdf_bytes: bytes, pdf_reader=None) -> str:
    text = extract_generated_pdf_text(pdf_bytes)
    if text.strip():
        return text

    if pdf_reader is not None:
        try:
            reader = pdf_reader(io.BytesIO(pdf_bytes))
            page_text = [page.extract_text() or "" for page in reader.pages]
            text = "\n".join(part for part in page_text if part.strip())
            if text.strip():
                return text
        except Exception:
            pass

    return extract_plain_blob_text(pdf_bytes)


def clean_extracted_text(text: str) -> str:
    # The older PL/SQL demo padded each synthetic section with a repeated
    # character to create large duplicate LOB regions. Strip those pads before
    # chunking so Vector Search indexes meaningful statement text.
    text = re.sub(r"([A-Za-z0-9])\1{80,}", "\n", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n[ \t]+", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def chunks(text: str, chunk_chars: int, overlap_chars: int) -> list[str]:
    clean = clean_extracted_text(text)
    if not clean:
        return []
    if len(clean) <= chunk_chars:
        return [clean]
    out = []
    start = 0
    while start < len(clean):
        end = min(start + chunk_chars, len(clean))
        if end < len(clean):
            boundary = clean.rfind("\n", start, end)
            if boundary > start + chunk_chars // 2:
                end = boundary
        piece = clean[start:end].strip()
        if piece:
            out.append(piece)
        if end >= len(clean):
            break
        start = max(end - overlap_chars, start + 1)
    return out


def has_column(cursor, table_name: str, column_name: str) -> bool:
    cursor.execute(
        """
        select count(*)
        from   user_tab_columns
        where  table_name = :table_name
        and    column_name = :column_name
        """,
        {
            "table_name": table_name.upper(),
            "column_name": column_name.upper(),
        },
    )
    return cursor.fetchone()[0] > 0


def source_sql(limit: int, include_file_name: bool) -> str:
    file_name_expr = (
        "file_name"
        if include_file_name
        else "'statement_' || to_char(statement_id, 'FM000000') || '_' || copy_role || '.pdf' as file_name"
    )
    base = """
        select statement_copy_id, statement_id, copy_role, account_no,
               statement_month, {file_name_expr}, pdf_document
        from   BANK_PDF_DEDUPLICATE
        order  by statement_copy_id
    """.format(file_name_expr=file_name_expr)
    if limit > 0:
        return f"select * from ({base}) where rownum <= :limit"
    return base


def main() -> None:
    args = parse_args()
    if args.overlap_chars >= args.chunk_chars:
        raise SystemExit("--overlap-chars must be smaller than --chunk-chars")
    oracledb = import_oracledb()
    pdf_reader = import_pypdf()
    if pdf_reader is None:
        print("pypdf is not installed; using lightweight generated-PDF extractor.", flush=True)
    else:
        print("Using pypdf for PDF text extraction.", flush=True)
    with connect(oracledb, args) as con:
        with con.cursor() as read_cur, con.cursor() as write_cur:
            if args.recreate:
                recreate(write_cur)

            include_file_name = has_column(write_cur, "BANK_PDF_DEDUPLICATE", "FILE_NAME")
            if not include_file_name:
                print("BANK_PDF_DEDUPLICATE.FILE_NAME not found; generating file names from statement_id/copy_role.", flush=True)

            read_cur.execute(source_sql(args.limit, include_file_name), {"limit": args.limit} if args.limit > 0 else {})
            batch: list[dict] = []
            pdf_rows = 0
            chunk_rows = 0
            empty_pdf_rows = 0
            for row in read_cur:
                (
                    statement_copy_id,
                    statement_id,
                    copy_role,
                    account_no,
                    statement_month,
                    file_name,
                    pdf_document,
                ) = row
                pdf_rows += 1
                pdf_bytes = pdf_document.read() if hasattr(pdf_document, "read") else bytes(pdf_document)
                text = extract_pdf_text(pdf_bytes, pdf_reader)
                if not text.strip():
                    empty_pdf_rows += 1
                for chunk_no, chunk_text in enumerate(chunks(text, args.chunk_chars, args.overlap_chars), start=1):
                    batch.append({
                        "statement_copy_id": statement_copy_id,
                        "statement_id": statement_id,
                        "copy_role": copy_role,
                        "account_no": account_no,
                        "statement_month": statement_month,
                        "file_name": file_name,
                        "chunk_no": chunk_no,
                        "chunk_text": chunk_text,
                    })
                    if len(batch) >= args.batch_size:
                        write_cur.executemany(INSERT_CHUNK, batch)
                        chunk_rows += len(batch)
                        print(f"Loaded {chunk_rows} chunks from {pdf_rows} PDFs...", flush=True)
                        batch.clear()
            if batch:
                write_cur.executemany(INSERT_CHUNK, batch)
                chunk_rows += len(batch)
            con.commit()
            print(f"Processed PDF rows: {pdf_rows}")
            print(f"Loaded chunk rows: {chunk_rows}")
            print(f"PDF rows with no extracted text: {empty_pdf_rows}")
            if pdf_rows > 0 and chunk_rows == 0:
                raise SystemExit(
                    "No PDF text was extracted. These PDFs likely need a full PDF text extractor "
                    "such as pypdf, PyMuPDF, or Oracle Text/media processing before vector chunking."
                )
            print("Next: run @bank_pdf_vector_search_setup.sql in SQLcl/SQL Developer.")


if __name__ == "__main__":
    main()
