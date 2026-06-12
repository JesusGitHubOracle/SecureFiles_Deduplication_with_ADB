# Oracle SecureFiles and AI Vector Search with Oracle Autonomous Database

This repository showcases Oracle SecureFiles deduplication along with AI vector Search in Oracle Autonomous Database. It also shows how to store unstructured data on external partitions for query offload and archiving.  

## References

- [Overview of Oracle SecureFiles](https://www.oracle.com/database/technologies/securefiles.html)
- [SecureFiles Documentation](https://docs.oracle.com/en/database/oracle/oracle-database/19/adlob/using-oracle-LOBs-storage.html)
- [SecureFiles Deduplication Examples](https://docs.oracle.com/en/database/oracle/oracle-database/26/adlob/creating-new-LOB-column.html)
- [Query Hybrid Partitioned Data](https://docs.oracle.com/en/cloud/paas/autonomous-database/serverless/adbsb/query-hybrid-partition.html)
- [Oracle AI Vector Search User’s Guide](https://docs.oracle.com/en/database/oracle/oracle-database/26/vecse/)

## Overview

The first script, `basic_deduplication.sql`, creates two SecureFiles tables with the same data: one keeps duplicates, one deduplicates them, then compares LOB segment storage.

The second script, `bank_pdfs_deduplication.sql`, uses generated bank-statement PDFs to show a more realistic pattern:

- Multiple exact copies of the same PDF statement are stored for different business purposes.
- A `KEEP_DUPLICATES` table stores every PDF copy separately.
- A `DEDUPLICATE` table stores duplicate SecureFiles LOB content once.
- Segment allocation is compared to show the actual storage savings.

The third script, `create_hybrid_bank_statement_table.sql`, creates a hybrid partitioned metadata table with cold monthly partitions in OCI Object Storage and a current-month internal SecureFiles BLOB table.

The fourth script, `archive_current_partition_to_object_storage.sql`, archives the current internal month to Object Storage and rebuilds the hybrid table so the archived month becomes an external partition.

## Files

- `basic_deduplication.sql`  
  Minimal SecureFiles deduplication example using synthetic LOB data.

- `generate_bank_pdfs.py`  
  Generates valid synthetic PDF bank statements outside the database.

- `load_bank_pdfs_to_adb.py`  
  Loads generated PDFs into Autonomous Database SecureFiles BLOB tables.

- `bank_pdfs_deduplication.sql`  
  SQL-only demo using PDF-like BLOB payloads.

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

## Oracle AI Vector Search

Oracle AI Vector Search can be easily used over the PDFs already loaded into `BANK_PDF_DEDUPLICATE`. This adds semantic search on top of the optinized storage: SecureFiles remains the source of truth for the PDF bytes, while extracted text chunks and vector embeddings make the statement content searchable by meaning.

The Vector Search flow is:

1. Extract text from `BANK_PDF_DEDUPLICATE.PDF_DOCUMENT`.
2. Split each statement into searchable text chunks.
3. Store the chunks in `BANK_PDF_VECTOR_CHUNKS`.
4. Load or verify an ONNX embedding model such as `ALL_MINILM_L12_V2`.
5. Generate database `VECTOR` embeddings in `BANK_PDF_VECTOR_EMBEDDINGS`.
6. Create a vector index for cosine similarity search.
7. Run natural-language searches over the bank statement content.

A PDF extraction pipeline is the step that turns stored PDF bytes into clean text that can be searched or embedded. In production this may include PDF parsing, OCR for scanned documents, text cleanup, metadata capture, and chunking. In this demo, `prepare_bank_pdf_vector_chunks.py` performs the extraction and chunk loading step.

Install the Python dependencies if needed:

```bash
python3 -m pip install oracledb pypdf
```

Prepare vector chunks:

```bash
python3 prepare_bank_pdf_vector_chunks.py --recreate
```

For a smaller smoke test:

```bash
python3 prepare_bank_pdf_vector_chunks.py --recreate --limit 25
```

Load the ONNX embedding model from Object Storage, if it is not already registered in the schema:

```sql
@load_all_minilm_model_from_par.sql
```

Then generate embeddings and create the vector index:

```sql
define EMBEDDING_MODEL = ALL_MINILM_L12_V2
@bank_pdf_vector_search_setup.sql
```

Run a semantic search:

```bash
python3 run_bank_pdf_vector_search.py \
  "fraud prevention and suspicious card activity" \
  --top-k 5 \
  --snippet-chars 800
```

Other useful demo prompts:

```bash
python3 run_bank_pdf_vector_search.py \
  "monthly maintenance ATM wire transfer and statement copy fees" \
  --top-k 5

python3 run_bank_pdf_vector_search.py \
  "electronic funds transfer error resolution and provisional credit" \
  --top-k 5

python3 run_bank_pdf_vector_search.py \
  "card purchases merchant transaction detail" \
  --top-k 5
```

The search result includes the statement id, copy role, account number, statement month, file name, chunk number, vector distance, and a relevant snippet. The chunk number is the sequential text chunk within that statement copy; it is not a page number.
