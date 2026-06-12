set echo on
set serveroutput on
set define on
set linesize 220
set pagesize 100

/*
  Oracle AI Vector Search demo over PDFs stored in BANK_PDF_DEDUPLICATE.

  Flow:
    1. Run prepare_bank_pdf_vector_chunks.py to extract text from PDF_DOCUMENT
       and load BANK_PDF_VECTOR_CHUNKS.
    2. Run this SQL script to generate embeddings inside the database.
    3. Run run_bank_pdf_vector_search.py, or use the sample SQL query below.

  Prerequisite:
    An embedding model must already be loaded in the database. The examples use
    all_MiniLM_L12_v2, which is commonly used in Oracle AI Vector Search demos.
    If your model has a different name, run this script with:

      define EMBEDDING_MODEL = '<your_model_name>'
      @bank_pdf_vector_search_setup.sql
*/

define EMBEDDING_MODEL = 'all_MiniLM_L12_v2'

prompt ======================================================================
prompt START bank_pdf_vector_search_setup.sql
prompt ======================================================================

show user

prompt Confirm source and chunk tables...

select table_name
from user_tables
where table_name in ('BANK_PDF_DEDUPLICATE', 'BANK_PDF_VECTOR_CHUNKS')
order by table_name;

prompt Available embedding/mining models in this schema...

column model_name format a40
column mining_function format a24
column algorithm format a32

select model_name, mining_function, algorithm
from   user_mining_models
order  by model_name;

prompt Validate prerequisites...

declare
  l_model_count number;
  l_chunk_count number;
  l_model_name  varchar2(128) := replace(q'[&&EMBEDDING_MODEL]', '''', '');
begin
  select count(*)
  into   l_chunk_count
  from   bank_pdf_vector_chunks;

  if l_chunk_count = 0 then
    raise_application_error(
      -20010,
      'BANK_PDF_VECTOR_CHUNKS is empty. Run prepare_bank_pdf_vector_chunks.py first.'
    );
  end if;

  select count(*)
  into   l_model_count
  from   user_mining_models
  where  upper(model_name) = upper(l_model_name);

  if l_model_count = 0 then
    raise_application_error(
      -20011,
      'Embedding model &&EMBEDDING_MODEL was not found in USER_MINING_MODELS. Load an ONNX embedding model first, or set EMBEDDING_MODEL to an existing model name shown above.'
    );
  end if;
end;
/

prompt Drop prior vector demo objects if they exist...

begin
  execute immediate 'drop table BANK_PDF_VECTOR_EMBEDDINGS purge';
exception
  when others then
    if sqlcode != -942 then
      raise;
    end if;
end;
/

whenever sqlerror exit sql.sqlcode

prompt Create vector table...

create table BANK_PDF_VECTOR_EMBEDDINGS (
  chunk_id  number primary key,
  embedding vector not null,
  constraint bank_pdf_vec_emb_chunk_fk
    foreign key (chunk_id)
    references BANK_PDF_VECTOR_CHUNKS (chunk_id)
);

prompt Generate embeddings from PDF text chunks...

insert /*+ append */ into BANK_PDF_VECTOR_EMBEDDINGS (chunk_id, embedding)
select chunk_id,
       vector_embedding(&&EMBEDDING_MODEL using chunk_text as data) as embedding
from   BANK_PDF_VECTOR_CHUNKS;

commit;

prompt Create an approximate vector index for cosine similarity search...

create vector index BANK_PDF_VECTOR_HNSW_IDX
on BANK_PDF_VECTOR_EMBEDDINGS (embedding)
organization inmemory neighbor graph
distance cosine
with target accuracy 95;

prompt Vector demo row counts...

select 'BANK_PDF_VECTOR_CHUNKS' as object_name, count(*) as row_count
from BANK_PDF_VECTOR_CHUNKS
union all
select 'BANK_PDF_VECTOR_EMBEDDINGS', count(*)
from BANK_PDF_VECTOR_EMBEDDINGS;

prompt Sample semantic search: fraud, suspicious activity, card lock...

column file_name format a48
column copy_role format a24
column snippet format a90

with query_vector as (
  select vector_embedding(&&EMBEDDING_MODEL using
           'fraud prevention, phishing warning, card lock, suspicious activity'
         as data) as v
  from dual
)
select c.statement_id,
       c.copy_role,
       c.file_name,
       round(vector_distance(e.embedding, q.v, cosine), 6) as distance,
       substr(replace(replace(c.chunk_text, chr(10), ' '), chr(13), ' '), 1, 160) as snippet
from   BANK_PDF_VECTOR_CHUNKS c
join   BANK_PDF_VECTOR_EMBEDDINGS e
  on   e.chunk_id = c.chunk_id
cross join query_vector q
order  by vector_distance(e.embedding, q.v, cosine)
fetch approximate first 10 rows only;

prompt ======================================================================
prompt END bank_pdf_vector_search_setup.sql
prompt ======================================================================
