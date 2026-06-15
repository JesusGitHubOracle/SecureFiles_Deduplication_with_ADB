# Oracle SecureFiles, Hybrid Partitioning, and AI Vector Search with Autonomous Database

This repository demonstrates how Oracle Autonomous Database can be used as a complete platform for storing, optimizing, archiving, and searching unstructured content.

The scripts follow the lifecycle of fictitious bank statement PDF documents through several stages:

1. Store documents as Oracle SecureFiles BLOBs.
2. Reduce storage consumption using SecureFiles Deduplication.
3. Archive historical content to OCI Object Storage using Hybrid Partitioned Tables.
4. Enable semantic document retrieval using Oracle AI Vector Search.

The result is a modern architecture that combines secure document storage, storage optimization, lifecycle management, and AI-powered search within a single database platform.

## Architecture Overview

The demonstration combines four Oracle technologies:

- Oracle SecureFiles for document storage
- SecureFiles Deduplication for storage optimization
- Hybrid Partitioned Tables for lifecycle management and archiving
- Oracle AI Vector Search for semantic document retrieval

Together these technologies create a complete platform for managing, archiving, and searching large collections of unstructured content.

## Stage 1 – Basic SecureFiles Deduplication  

Demonstrates SecureFiles deduplication using synthetic CLOB data. Two identical SecureFiles tables are created:

* KEEP_DUPLICATES
* DEDUPLICATE

The script compares physical storage consumption and demonstrates the maximum potential storage savings.
  
## Stage 2 – Realistic PDF Deduplication  

Demonstrates deduplication using bank statement PDFs. Multiple copies of the same PDF statement are stored for different business purposes:

* Customer access
* Compliance retention
* Customer support
* Archival copies

The demo compares storage allocation with and without deduplication enabled.  

## Stage 3 – Hybrid Partitioned Tables and Archive Historical Data

Introduces Information Lifecycle Management.

Recent statements remain inside the database as SecureFiles BLOBs, while historical statements are archived to OCI Object Storage using Hybrid Partitioned Tables. Applications continue querying a single logical dataset without needing to know where the data is physically stored.

The archive process performs the following steps:

* Exports PDF documents
* Uploads files to Object Storage
* Generates manifest files
* Converts archived months into external partitions

This reduces database storage requirements while preserving transparent access.

## Stage 4 – AI Vector Search  

Demonstrates semantic search over the stored PDF documents.

The process includes:

* PDF text extraction
* Text chunking
* Embedding generation
* Vector indexing
* Natural-language search

Oracle AI Vector Search allows users to search document content by meaning rather than exact keywords, providing a more natural and effective search experience.

## Example Queries

```bash
python3 run_bank_pdf_vector_search.py \
  "fraud prevention and suspicious card activity"
```

```bash
python3 run_bank_pdf_vector_search.py \
  "electronic funds transfer error resolution"
```

```bash
python3 run_bank_pdf_vector_search.py \
  "monthly maintenance fees and wire transfer charges"
```

---

## Repository Contents

| Script | Description |
|----------|-------------|
| basic_deduplication.sql | Demonstrates SecureFiles deduplication using synthetic CLOB data. |
| generate_bank_pdfs.py | Generates sample bank statement PDFs with configurable duplication levels. |
| load_bank_pdfs_to_adb.py | Loads generated PDFs into SecureFiles BLOB tables in Autonomous Database. |
| bank_pdfs_deduplication.sql | Demonstrates SecureFiles deduplication using realistic PDF workloads. |
| create_hybrid_bank_statement_table.sql | Creates a Hybrid Partitioned Table architecture for active and archived statements. |
| archive_current_partition_to_object_storage.sql | Archives SecureFiles PDFs to OCI Object Storage and converts partitions to external storage. |
| prepare_bank_pdf_vector_chunks.py | Extracts PDF text and loads searchable chunks into the database. |
| load_all_minilm_model_from_par.sql | Registers the MiniLM embedding model in Oracle Database. |
| bank_pdf_vector_search_setup.sql | Generates vector embeddings and creates vector indexes. |
| run_bank_pdf_vector_search.py | Executes semantic searches against bank statement content. |

## Installation

### Python Dependencies

```bash
python3 -m pip install oracledb
```

For PDF extraction:

```bash
python3 -m pip install pypdf
```

---

### Generate Sample PDFs

```bash
python3 generate_bank_pdfs.py \
  --unique-statements 300 \
  --copies-per-statement 3 \
  --out-dir generated_bank_pdfs
```

---

### Load PDFs into Autonomous Database

```bash
python3 load_bank_pdfs_to_adb.py \
  --dsn '<adb-connect-descriptor>' \
  --user '<db-user>' \
  --input-dir generated_bank_pdfs \
  --recreate \
  --batch-size 100 \
  --tls-insecure-skip-verify
```

---

### Run the Deduplication Demo

```sql
@basic_deduplication.sql
```

```sql
@bank_pdfs_deduplication.sql
```

---

### Run the Hybrid Partitioning Demo

```sql
@create_hybrid_bank_statement_table.sql
```

```sql
@archive_current_partition_to_object_storage.sql
```

---

### Run the Vector Search Demo

Prepare chunks:

```bash
python3 prepare_bank_pdf_vector_chunks.py --recreate
```

Load the embedding model:

```sql
@load_all_minilm_model_from_par.sql
```

Create embeddings and vector indexes:

```sql
define EMBEDDING_MODEL = ALL_MINILM_L12_V2
@bank_pdf_vector_search_setup.sql
```

Run semantic searches:

```bash
python3 run_bank_pdf_vector_search.py \
  "fraud prevention and suspicious card activity"
```

## References

- Oracle SecureFiles Overview
  https://www.oracle.com/database/technologies/securefiles.html

- SecureFiles Documentation
  https://docs.oracle.com/en/database/oracle/oracle-database/19/adlob/

- Hybrid Partitioned Tables
  https://docs.oracle.com/en/cloud/paas/autonomous-database/serverless/adbsb/query-hybrid-partition.html

- Oracle AI Vector Search User Guide
  https://docs.oracle.com/en/database/oracle/oracle-database/26/vecse/