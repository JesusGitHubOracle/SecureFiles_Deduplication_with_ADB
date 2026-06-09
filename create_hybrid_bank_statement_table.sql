set echo on
set serveroutput on
set define on
set linesize 220
set pagesize 100

define OBJECT_STORAGE_BASE_URI = 'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/<prefix>'

prompt ======================================================================
prompt START create_hybrid_bank_statement_table.sql
prompt This script must be run from the beginning, not from the Query examples section.
prompt ======================================================================

show user

/*
  Hybrid partitioned bank-statement demo for Autonomous Database.

  Design:
    - Cold monthly partitions are external partitions in OCI Object Storage.
    - The hybrid table stores statement metadata and a PDF URI.
    - The current-month PDF BLOBs are stored in a separate internal table,
      partitioned by date, with SecureFiles DEDUPLICATE.

  Why two tables?
    Autonomous Database hybrid partitioned tables do not support BLOB columns.
    The supported pattern is to keep cold PDF bytes in Object Storage and keep
    current hot PDF bytes in a normal internal SecureFiles table.

  Important:
    DBMS_CLOUD.CREATE_HYBRID_PART_TABLE external partitions query structured
    files such as CSV/JSON/Parquet. If the Object Storage prefix contains raw
    PDF files only, create a CSV manifest per cold month with one row per PDF.

    Suggested cold manifest format:
      statement_copy_id,statement_id,copy_role,account_no,statement_month,pdf_uri,mime_type,file_name

    Example pdf_uri value:
      &&OBJECT_STORAGE_BASE_URI/2026/01/statement_000001_ONLINE_STATEMENT.pdf

  Credential:
    OBJ_STORE_CRED must already exist in this schema.
*/

prompt Drop prior demo objects if they exist...

begin
  execute immediate 'drop view BANK_STATEMENT_PDF_ALL_V';
exception
  when others then
    if sqlcode != -942 then
      raise;
    end if;
end;
/

begin
  execute immediate 'drop table BANK_STATEMENT_PDF_CURRENT_LOB purge';
exception
  when others then
    if sqlcode != -942 then
      raise;
    end if;
end;
/

begin
  execute immediate 'drop table BANK_STATEMENT_PDF_HPT purge';
exception
  when others then
    if sqlcode != -942 then
      raise;
    end if;
end;
/

whenever sqlerror exit sql.sqlcode

prompt Create hybrid partitioned table...

declare
  l_partitioning_clause varchar2(32767);
begin
  l_partitioning_clause :=
    'partition by range (statement_month)
     (
       partition p_2026_01 values less than (to_date(''2026-02-01'',''YYYY-MM-DD'')) external location
         ( ''&&OBJECT_STORAGE_BASE_URI/manifests/statement_month=2026-01/*.csv'' ),
       partition p_2026_02 values less than (to_date(''2026-03-01'',''YYYY-MM-DD'')) external location
         ( ''&&OBJECT_STORAGE_BASE_URI/manifests/statement_month=2026-02/*.csv'' ),
       partition p_2026_03 values less than (to_date(''2026-04-01'',''YYYY-MM-DD'')) external location
         ( ''&&OBJECT_STORAGE_BASE_URI/manifests/statement_month=2026-03/*.csv'' ),
       partition p_2026_04 values less than (to_date(''2026-05-01'',''YYYY-MM-DD'')) external location
         ( ''&&OBJECT_STORAGE_BASE_URI/manifests/statement_month=2026-04/*.csv'' ),
       partition p_2026_05 values less than (to_date(''2026-06-01'',''YYYY-MM-DD'')) external location
         ( ''&&OBJECT_STORAGE_BASE_URI/manifests/statement_month=2026-05/*.csv'' ),
       partition p_2026_06_current values less than (to_date(''2026-07-01'',''YYYY-MM-DD''))
     )';

  dbms_output.put_line('Partitioning clause passed to DBMS_CLOUD:');
  dbms_output.put_line(l_partitioning_clause);

  dbms_cloud.create_hybrid_part_table(
    table_name      => 'BANK_STATEMENT_PDF_HPT',
    credential_name => 'OBJ_STORE_CRED',
    format          => '{
                         "type": "csv",
                         "delimiter": ",",
                         "quote": "\"",
                         "skipheaders": "1",
                         "recorddelimiter": "newline",
                         "ignoremissingcolumns": "true",
                         "ignoreblanklines": "true"
                       }',
    column_list     => '
      statement_copy_id number,
      statement_id      number,
      copy_role         varchar2(30),
      account_no        varchar2(30),
      statement_month   date,
      pdf_uri           varchar2(4000),
      mime_type         varchar2(30),
      file_name         varchar2(256)
    ',
    field_list      => '
      statement_copy_id,
      statement_id,
      copy_role,
      account_no,
      statement_month date mask "YYYY-MM-DD",
      pdf_uri,
      mime_type,
      file_name
    ',
    partitioning_clause => l_partitioning_clause
  );
end;
/

prompt Confirm hybrid metadata table exists...

declare
  l_count number;
begin
  select count(*)
  into   l_count
  from   user_tables
  where  table_name = upper('BANK_STATEMENT_PDF_HPT');

  if l_count = 0 then
    raise_application_error(-20001, 'Hybrid metadata table BANK_STATEMENT_PDF_HPT was not created.');
  end if;
end;
/

prompt Create current-month internal SecureFiles BLOB table with deduplication...

create table BANK_STATEMENT_PDF_CURRENT_LOB (
  statement_copy_id number primary key,
  statement_id      number not null,
  copy_role         varchar2(30),
  account_no        varchar2(30),
  statement_month   date not null,
  pdf_document      blob,
  mime_type         varchar2(30),
  file_name         varchar2(256)
)
lob (pdf_document) store as securefile (
  deduplicate
  nocompress
  nocache
  logging
)
partition by range (statement_month)
(
  partition p_2026_06_current values less than (date '2026-07-01')
);

prompt Load current-month metadata into the internal HPT partition...

insert /*+ append */ into BANK_STATEMENT_PDF_HPT (
  statement_copy_id,
  statement_id,
  copy_role,
  account_no,
  statement_month,
  pdf_uri,
  mime_type,
  file_name
)
select statement_copy_id,
       statement_id,
       copy_role,
       account_no,
       date '2026-06-01' as statement_month,
       'DB_CURRENT_PARTITION:statement_' ||
         to_char(statement_id, 'FM000000') || '_' || copy_role || '.pdf' as pdf_uri,
       mime_type,
       'statement_' || to_char(statement_id, 'FM000000') || '_' || copy_role || '.pdf' as file_name
from bank_pdf_deduplicate;

prompt Load current-month PDF BLOBs into the SecureFiles deduplicated table...

insert /*+ append */ into BANK_STATEMENT_PDF_CURRENT_LOB (
  statement_copy_id,
  statement_id,
  copy_role,
  account_no,
  statement_month,
  pdf_document,
  mime_type,
  file_name
)
select statement_copy_id,
       statement_id,
       copy_role,
       account_no,
       date '2026-06-01' as statement_month,
       pdf_document,
       mime_type,
       'statement_' || to_char(statement_id, 'FM000000') || '_' || copy_role || '.pdf' as file_name
from bank_pdf_deduplicate;

commit;

prompt Create a convenience view. Cold rows expose PDF_URI; current rows also expose PDF_DOCUMENT...

prompt Confirm source objects for the view exist...

select table_name
from user_tables
where table_name in (upper('BANK_STATEMENT_PDF_HPT'), upper('BANK_STATEMENT_PDF_CURRENT_LOB'))
order by table_name;

create or replace view BANK_STATEMENT_PDF_ALL_V as
select statement_copy_id,
       statement_id,
       copy_role,
       account_no,
       statement_month,
       pdf_uri,
       mime_type,
       file_name,
       to_blob(null) as pdf_document
from BANK_STATEMENT_PDF_HPT
where statement_month < date '2026-06-01'
union all
select h.statement_copy_id,
       h.statement_id,
       h.copy_role,
       h.account_no,
       h.statement_month,
       h.pdf_uri,
       h.mime_type,
       h.file_name,
       c.pdf_document
from BANK_STATEMENT_PDF_HPT h
join BANK_STATEMENT_PDF_CURRENT_LOB c
  on c.statement_copy_id = h.statement_copy_id
 and c.statement_month = h.statement_month
where h.statement_month >= date '2026-06-01'
and   h.statement_month <  date '2026-07-01';

prompt Show partitions and intended storage location...

column table_name format a28
column partition_name format a24
column high_value format a36
column storage_location format a18

select table_name,
       partition_name,
       high_value,
       case
         when partition_name = 'P_2026_06_CURRENT' then 'INTERNAL_DATABASE'
         else 'EXTERNAL_OBJECT'
       end as storage_location
from user_tab_partitions
where table_name = upper('BANK_STATEMENT_PDF_HPT')
order by partition_position;

prompt Show SecureFiles LOB settings for the current-month internal BLOB table...

column column_name format a20
column segment_name format a30
column securefile format a10
column deduplication format a15
column compression format a12

select table_name,
       column_name,
       segment_name,
       securefile,
       deduplication,
       compression
from user_lobs
where table_name = upper('BANK_STATEMENT_PDF_CURRENT_LOB');

prompt Query examples...

prompt Current month metadata query example, disabled by default to avoid external partition access:
prompt select count(*) from BANK_STATEMENT_PDF_HPT partition (p_2026_06_current);

prompt Cold month query example, disabled by default because it requires manifest files to exist:
prompt select statement_month, count(*) from BANK_STATEMENT_PDF_HPT where statement_month < date '2026-06-01' group by statement_month;

prompt Current-month internal LOB allocation:
column allocated_mb format 999,999,990.00

select l.table_name,
       l.deduplication,
       round(s.bytes / 1024 / 1024, 2) as allocated_mb
from user_lobs l
join user_segments s
  on s.segment_name = l.segment_name
where l.table_name = upper('BANK_STATEMENT_PDF_CURRENT_LOB')
and   l.column_name = 'PDF_DOCUMENT';

prompt Current-month internal rows with BLOBs:
select count(*) as current_rows_with_blob
from BANK_STATEMENT_PDF_CURRENT_LOB
where statement_month >= date '2026-06-01'
and   statement_month <  date '2026-07-01'
and   pdf_document is not null;

prompt View query example, disabled by default because it can touch external partitions:
prompt select count(*) from BANK_STATEMENT_PDF_ALL_V where statement_month >= date '2026-06-01' and statement_month < date '2026-07-01';

prompt Hybrid bank statement demo script completed.

prompt Final object check:

select object_name,
       object_type,
       status
from user_objects
where object_name in (
  'BANK_STATEMENT_PDF_HPT',
  'BANK_STATEMENT_PDF_CURRENT_LOB',
  'BANK_STATEMENT_PDF_ALL_V'
)
order by object_type, object_name;

prompt Final row check:

select count(*) as current_lob_rows
from bank_statement_pdf_current_lob;

prompt ======================================================================
prompt END create_hybrid_bank_statement_table.sql
prompt ======================================================================
