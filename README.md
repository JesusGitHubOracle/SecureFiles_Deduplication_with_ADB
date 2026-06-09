# SecureFiles Deduplication with Oracle Autonomous Database

This demo shows how to use Oracle SecureFiles deduplication with bank-statement PDF workloads in Oracle Autonomous Database.

## References

- [Overview of Oracle SecureFiles](https://www.oracle.com/database/technologies/securefiles.html)
- [SecureFiles Documentation](https://docs.oracle.com/en/database/oracle/oracle-database/19/adlob/using-oracle-LOBs-storage.html)
- [SecureFiles Deduplication Examples](https://docs.oracle.com/en/database/oracle/oracle-database/26/adlob/creating-new-LOB-column.html)

## Demo Overview

This script creates two SecureFiles tables with the same data: one keeps duplicates, one deduplicates them, then compares LOB segment storage using `DBMS_SECUREFILES.GET_LOB_DEDUPLICATION_RATIO`.

The extended demo uses generated bank-statement PDFs to show a more realistic pattern:

- Multiple exact copies of the same PDF statement are stored for different business purposes.
- A `KEEP_DUPLICATES` table stores every PDF copy separately.
- A `DEDUPLICATE` table stores duplicate SecureFiles LOB content once.
- Segment allocation is compared to show the actual storage savings.

## Files

- `basic_deduplication.sql`  
  Minimal SecureFiles deduplication example using synthetic LOB data.

- `bank_pdfs_deduplication.sql`  
  SQL-only demo using PDF-like BLOB payloads.

- `generate_bank_pdfs.py`  
  Generates valid synthetic PDF bank statements outside the database.

- `load_bank_pdfs_to_adb.py`  
  Loads generated PDFs into Autonomous Database SecureFiles BLOB tables.

- `create_hybrid_bank_statement_table.sql`  
  Creates a hybrid partitioned metadata table for cold Object Storage partitions and a current-month internal SecureFiles BLOB table with deduplication.

- `archive_current_partition_to_object_storage.sql`  
  Archives the current internal partition to Object Storage and rebuilds the hybrid table so the archived month becomes external.

## Architecture

The hybrid partitioned table demo uses a split design because Autonomous Database hybrid partitioned tables do not support `BLOB` columns.

- Cold months are represented in a hybrid partitioned metadata table.
- Cold PDF bytes live in OCI Object Storage.
- Current-month PDF bytes live in an internal SecureFiles BLOB table.
- The current-month BLOB table uses SecureFiles `DEDUPLICATE`.
- A view provides a common query shape for metadata and current BLOB access.

## Generate PDFs

```bash
python3 generate_bank_pdfs.py \
  --unique-statements 300 \
  --copies-per-statement 3 \
  --out-dir generated_bank_pdfs
```

## Load PDFs into Autonomous Database

Install the Python driver if needed:

```bash
python3 -m pip install oracledb
```

Example TLS connection:

```bash
python3 load_bank_pdfs_to_adb.py \
  --dsn '<your-adb-tls-connect-descriptor>' \
  --user '<db-user>' \
  --input-dir generated_bank_pdfs \
  --recreate \
  --batch-size 100 \
  --tls-insecure-skip-verify
```

For production usage, configure certificate validation instead of using `--tls-insecure-skip-verify`.

## Expected Deduplication Result

With three stored copies per generated statement, the SecureFiles deduplication ratio should usually be close to `3:1`, with some overhead from LOB metadata and extent allocation.

Example result from the demo:

```text
KEEP_DUPLICATES allocated MB: 40.31
DEDUPLICATE allocated MB: 16.25
Actual dedup ratio: 2.48
```

This means the deduplicated table used significantly less allocated LOB segment space while preserving the same logical PDF documents.

## Hybrid Partitioned Table Flow

Create the hybrid metadata table and current SecureFiles table:

```sql
@create_hybrid_bank_statement_table.sql
```

Archive the current internal partition to Object Storage:

```sql
@archive_current_partition_to_object_storage.sql
```

The archive script writes PDFs and manifest files to OCI Object Storage, then rebuilds the hybrid metadata table so the archived month is external and the next month becomes the current internal partition.

## Notes

- SecureFiles deduplication applies to SecureFiles LOBs stored inside the database.
- External Object Storage partitions store metadata and object URIs, not database SecureFiles BLOBs.
- Raw PDFs in Object Storage are not directly queryable as table rows; the demo uses CSV manifests to represent Object Storage PDFs in the hybrid metadata table.
- Always verify archived Object Storage files and manifest row counts before purging the internal SecureFiles partition.

