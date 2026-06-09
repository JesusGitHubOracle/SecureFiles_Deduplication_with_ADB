set echo on
set serveroutput on
set define on
set linesize 220
set pagesize 100

define OBJECT_STORAGE_BASE_URI = 'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/<prefix>'

prompt ======================================================================
prompt START archive_current_partition_to_object_storage.sql
prompt Archives June 2026 current DB partition metadata/PDFs to OCI Object Storage
prompt and rebuilds BANK_STATEMENT_PDF_HPT with June as an external partition.
prompt ======================================================================

show user

/*
  Why this script rebuilds the HPT:
    Oracle hybrid partitioned tables do not support a direct "move internal
    partition to external partition" operation. Oracle documents exchange with
    an external table as the supported partition mechanism, and notes that
    moving data between internal and external storage is a separate operation.

  This ADB demo uses DBMS_CLOUD-created CSV external partitions, so the archive
  flow is:
    1. Copy current-month PDF BLOBs to Object Storage with DBMS_CLOUD.PUT_OBJECT.
    2. Write a CSV manifest for the month to Object Storage.
    3. Create a replacement hybrid metadata table where June is external and
       July is the next internal/current DB partition.
    4. Swap the replacement HPT into the original table name.

  The SecureFiles BLOB table is NOT purged by default. Verify Object Storage
  files and HPT queries first, then run the cleanup statements at the bottom if
  you want to reclaim database storage.
*/

whenever sqlerror exit sql.sqlcode

prompt Confirm required source tables exist...

select table_name
from user_tables
where table_name in (
  'BANK_STATEMENT_PDF_HPT',
  'BANK_STATEMENT_PDF_CURRENT_LOB'
)
order by table_name;

prompt Current internal BLOB rows to archive...

select count(*) as june_rows_to_archive
from bank_statement_pdf_current_lob
where statement_month >= date '2026-06-01'
and   statement_month <  date '2026-07-01'
and   pdf_document is not null;

prompt Upload June PDF BLOBs and June CSV manifest to Object Storage...

declare
  c_credential_name constant varchar2(128) := 'OBJ_STORE_CRED';
  c_base_uri        constant varchar2(4000) :=
    '&&OBJECT_STORAGE_BASE_URI';
  c_pdf_prefix      constant varchar2(4000) := c_base_uri || '/2026/06/';
  c_manifest_uri    constant varchar2(4000) :=
    c_base_uri || '/manifests/statement_month=2026-06/bank_statement_manifest_2026_06.csv';

  l_manifest        blob;
  l_line            varchar2(32767);
  l_raw             raw(32767);
  l_pdf_uri         varchar2(4000);
  l_uploaded_count  number := 0;

  function csv_value(p_value varchar2) return varchar2 is
  begin
    return '"' || replace(nvl(p_value, ''), '"', '""') || '"';
  end;

  procedure append_manifest_line(p_line varchar2) is
  begin
    l_raw := utl_raw.cast_to_raw(p_line || chr(10));
    dbms_lob.writeappend(l_manifest, utl_raw.length(l_raw), l_raw);
  end;
begin
  dbms_lob.createtemporary(l_manifest, true);

  append_manifest_line(
    'statement_copy_id,statement_id,copy_role,account_no,statement_month,pdf_uri,mime_type,file_name'
  );

  for r in (
    select statement_copy_id,
           statement_id,
           copy_role,
           account_no,
           statement_month,
           pdf_document,
           mime_type,
           file_name
    from bank_statement_pdf_current_lob
    where statement_month >= date '2026-06-01'
    and   statement_month <  date '2026-07-01'
    and   pdf_document is not null
    order by statement_copy_id
  ) loop
    l_pdf_uri := c_pdf_prefix || r.file_name;

    dbms_cloud.put_object(
      credential_name => c_credential_name,
      object_uri      => l_pdf_uri,
      contents        => r.pdf_document
    );

    l_line :=
      r.statement_copy_id || ',' ||
      r.statement_id || ',' ||
      csv_value(r.copy_role) || ',' ||
      csv_value(r.account_no) || ',' ||
      to_char(r.statement_month, 'YYYY-MM-DD') || ',' ||
      csv_value(l_pdf_uri) || ',' ||
      csv_value(r.mime_type) || ',' ||
      csv_value(r.file_name);

    append_manifest_line(l_line);
    l_uploaded_count := l_uploaded_count + 1;

    if mod(l_uploaded_count, 100) = 0 then
      dbms_output.put_line('Uploaded ' || l_uploaded_count || ' PDFs...');
    end if;
  end loop;

  dbms_cloud.put_object(
    credential_name => c_credential_name,
    object_uri      => c_manifest_uri,
    contents        => l_manifest
  );

  dbms_output.put_line('Uploaded PDF count: ' || l_uploaded_count);
  dbms_output.put_line('Manifest URI: ' || c_manifest_uri);

  dbms_lob.freetemporary(l_manifest);
end;
/

prompt List archived June objects in Object Storage...

select object_name,
       bytes
from dbms_cloud.list_objects(
       credential_name => 'OBJ_STORE_CRED',
       location_uri    => '&&OBJECT_STORAGE_BASE_URI/manifests/statement_month=2026-06/'
     );

prompt Drop prior replacement/backup HPT objects if they exist...

begin
  execute immediate 'drop table BANK_STATEMENT_PDF_HPT_NEW purge';
exception
  when others then
    if sqlcode != -942 then
      raise;
    end if;
end;
/

begin
  execute immediate 'drop table BANK_STATEMENT_PDF_HPT_BEFORE_JUNE_ARCHIVE purge';
exception
  when others then
    if sqlcode != -942 then
      raise;
    end if;
end;
/

prompt Create replacement HPT: Jan-Jun external, July internal/current...

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
       partition p_2026_06 values less than (to_date(''2026-07-01'',''YYYY-MM-DD'')) external location
         ( ''&&OBJECT_STORAGE_BASE_URI/manifests/statement_month=2026-06/*.csv'' ),
       partition p_2026_07_current values less than (to_date(''2026-08-01'',''YYYY-MM-DD''))
     )';

  dbms_output.put_line('Replacement partitioning clause:');
  dbms_output.put_line(l_partitioning_clause);

  dbms_cloud.create_hybrid_part_table(
    table_name      => 'BANK_STATEMENT_PDF_HPT_NEW',
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

prompt Swap replacement HPT into the original table name...

drop view BANK_STATEMENT_PDF_ALL_V;

alter table BANK_STATEMENT_PDF_HPT rename to BANK_STATEMENT_PDF_HPT_BEFORE_JUNE_ARCHIVE;
alter table BANK_STATEMENT_PDF_HPT_NEW rename to BANK_STATEMENT_PDF_HPT;

prompt Recreate convenience view. Cold rows expose PDF_URI; July current rows can join BLOB table later...

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
where statement_month < date '2026-07-01'
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
where h.statement_month >= date '2026-07-01'
and   h.statement_month <  date '2026-08-01';

prompt Verify replacement HPT partitions...

column table_name format a28
column partition_name format a24
column high_value format a36
column storage_location format a18

select table_name,
       partition_name,
       high_value,
       case
         when partition_name = 'P_2026_07_CURRENT' then 'INTERNAL_DATABASE'
         else 'EXTERNAL_OBJECT'
       end as storage_location
from user_tab_partitions
where table_name = 'BANK_STATEMENT_PDF_HPT'
order by partition_position;

prompt Verify June external manifest row count. This reads the June manifest from Object Storage.

select count(*) as june_external_metadata_rows
from bank_statement_pdf_hpt partition (p_2026_06);

prompt Verify internal BLOB table still exists. It is retained until you choose to purge it.

select count(*) as retained_june_blob_rows
from bank_statement_pdf_current_lob
where statement_month >= date '2026-06-01'
and   statement_month <  date '2026-07-01'
and   pdf_document is not null;

prompt Optional cleanup after external archive verification:
prompt alter table BANK_STATEMENT_PDF_CURRENT_LOB truncate partition p_2026_06_current;
prompt drop table BANK_STATEMENT_PDF_HPT_BEFORE_JUNE_ARCHIVE purge;

prompt ======================================================================
prompt END archive_current_partition_to_object_storage.sql
prompt ======================================================================
