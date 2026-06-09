#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from datetime import date, timedelta
from pathlib import Path

COPY_ROLES = ("ONLINE_STATEMENT", "COMPLIANCE_ARCHIVE", "CUSTOMER_SERVICE_COPY", "REPRINT_COPY")


def esc(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def stream(title: str, lines: list[str]) -> bytes:
    cmds = ["BT", "/F1 16 Tf", "72 742 Td", f"({esc(title)}) Tj", "/F1 9 Tf", "0 -24 Td"]
    for line in lines[:45]:
        cmds.append(f"({esc(line)}) Tj")
        cmds.append("0 -13 Td")
    cmds.append("ET")
    return ("\n".join(cmds) + "\n").encode("latin-1")


def add_obj(objects: list[bytes], body: bytes | str) -> int:
    objects.append(body.encode("latin-1") if isinstance(body, str) else body)
    return len(objects)


def wrapped(text: str, width: int = 88) -> list[str]:
    out, line = [], []
    for word in text.split():
        candidate = " ".join([*line, word])
        if len(candidate) > width and line:
            out.append(" ".join(line))
            line = [word]
        else:
            line.append(word)
    if line:
        out.append(" ".join(line))
    return out


def boilerplate_pages() -> list[tuple[str, str]]:
    return [
        ("Bank Header", "ACME Bank monthly checking statement template. Member FDIC. Standard branch, contact, routing, and digital banking language. " * 8),
        ("Privacy Policy", "Standard privacy notice for collection, use, retention, sharing, and protection of customer information. " * 10),
        ("Electronic Funds Transfer Notice", "Standard EFT rights, consumer liability, error resolution timelines, and provisional credit terms. " * 10),
        ("Funds Availability Policy", "Standard deposit cut-off, check hold, mobile deposit, ATM deposit, and next-business-day availability disclosure. " * 10),
        ("Overdraft Policy", "Standard overdraft service description, opt-in rules, fee assessment, and available balance calculation. " * 10),
        ("Fee Schedule", "Standard monthly maintenance, ATM, ACH, wire transfer, stop payment, returned item, and statement copy fees. " * 10),
        ("Security Center Notice", "Standard fraud prevention, phishing warning, password safety, card lock, and suspicious activity instructions. " * 10),
        ("Dispute Resolution Notice", "Standard card dispute, ACH dispute, billing error, claim submission, and investigation procedures. " * 10),
    ]


def tx_lines(statement_id: int, page_no: int) -> list[str]:
    start = date(2026, 5, 1)
    lines = [
        f"Statement ID: {statement_id:06d}",
        f"Account: ACCT-{1000000000 + statement_id}",
        "Date        Description                              Amount",
        "----------  ---------------------------------------  --------",
    ]
    for i in range(1, 24):
        posted = start + timedelta(days=(i + statement_id + page_no) % 28)
        amount = ((statement_id * i) % 250) + 1 + (((statement_id + i) % 99) / 100)
        lines.append(
            f"{posted:%Y-%m-%d}  CARD PURCHASE REF {statement_id:06d}-{page_no:02d}-{i:03d} "
            f"MERCHANT-{(statement_id * i * page_no) % 997:03d}  ${amount:7.2f}"
        )
    return lines


def content_object(objects: list[bytes], page_stream: bytes) -> int:
    return add_obj(objects, b"<< /Length " + str(len(page_stream)).encode("ascii") + b" >>\nstream\n" + page_stream + b"endstream")


def build_pdf(statement_id: int) -> bytes:
    objects: list[bytes] = []
    add_obj(objects, "<< /Type /Catalog /Pages 2 0 R >>")
    add_obj(objects, b"__PAGES__")
    add_obj(objects, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    pages: list[int] = []

    cover = stream("Monthly Statement", [
        "ACME Bank Monthly Checking Statement",
        "Statement date: 2026-05-31",
        f"Statement ID: {statement_id:06d}",
        f"Account number: ACCT-{1000000000 + statement_id}",
        "Synthetic test PDF for Oracle SecureFiles BLOB deduplication.",
    ])
    cid = content_object(objects, cover)
    pages.append(add_obj(objects, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {cid} 0 R >>"))

    for title, text in boilerplate_pages():
        cid = content_object(objects, stream(title, wrapped(text)))
        pages.append(add_obj(objects, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {cid} 0 R >>"))

    for page_no in range(1, 7):
        cid = content_object(objects, stream(f"Transaction Detail Page {page_no}", tx_lines(statement_id, page_no)))
        pages.append(add_obj(objects, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {cid} 0 R >>"))

    kids = " ".join(f"{p} 0 R" for p in pages)
    objects[1] = f"<< /Type /Pages /Count {len(pages)} /Kids [ {kids} ] >>".encode("latin-1")

    pdf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for oid, body in enumerate(objects, start=1):
        offsets.append(len(pdf))
        pdf.extend(f"{oid} 0 obj\n".encode("ascii"))
        pdf.extend(body)
        pdf.extend(b"\nendobj\n")
    xref = len(pdf)
    pdf.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    pdf.extend(b"0000000000 65535 f \n")
    for off in offsets[1:]:
        pdf.extend(f"{off:010d} 00000 n \n".encode("ascii"))
    pdf.extend(f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii"))
    return bytes(pdf)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default="generated_bank_pdfs")
    parser.add_argument("--unique-statements", type=int, default=300)
    parser.add_argument("--copies-per-statement", type=int, default=3, choices=(1, 2, 3, 4))
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Generating PDFs in {out_dir}...", flush=True)
    interval = max(args.unique_statements // 10, 1)
    manifest = []
    copy_id = 0
    total_bytes = 0

    for statement_id in range(1, args.unique_statements + 1):
        pdf = build_pdf(statement_id)
        for copy_no in range(1, args.copies_per_statement + 1):
            copy_id += 1
            role = COPY_ROLES[copy_no - 1]
            file_name = f"statement_{statement_id:06d}_{role}.pdf"
            (out_dir / file_name).write_bytes(pdf)
            total_bytes += len(pdf)
            manifest.append({
                "statement_copy_id": copy_id,
                "statement_id": statement_id,
                "copy_role": role,
                "account_no": f"ACCT-{1000000000 + statement_id}",
                "statement_month": "2026-05-31",
                "mime_type": "application/pdf",
                "file_name": file_name,
                "size_bytes": len(pdf),
            })
        if statement_id % interval == 0 or statement_id == args.unique_statements:
            print(f"Generated {statement_id}/{args.unique_statements} unique statements ({copy_id} PDF files)...", flush=True)

    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"Wrote {len(manifest)} PDFs to {out_dir}", flush=True)
    print(f"Average PDF size: {total_bytes / len(manifest) / 1024:.2f} KB", flush=True)
    print(f"Manifest: {out_dir / 'manifest.json'}", flush=True)


if __name__ == "__main__":
    main()
