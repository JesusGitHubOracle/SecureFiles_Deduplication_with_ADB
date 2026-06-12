set echo on
set serveroutput on size unlimited
set define on
set linesize 220
set pagesize 100

/*
  SQL/PLSQL version of prepare_bank_pdf_vector_chunks.py.

  Purpose:
    Read synthetic PDF BLOBs from BANK_PDF_DEDUPLICATE, extract text from
    simple PDF text operators, split the text into overlapping chunks, and
    load BANK_PDF_VECTOR_CHUNKS for Oracle AI Vector Search.

  Important:
    This parser is intentionally demo-oriented. It works with the simple
    generated PDFs from generate_bank_pdfs.py, where text appears as:

      (...) Tj

    It is not a general-purpose PDF parser for arbitrary production PDFs.

  Optional SQLcl / SQL*Plus overrides:

    define SOURCE_LIMIT = 100
    define CHUNK_CHARS = 1800
    define OVERLAP_CHARS = 200
    @prepare_bank_pdf_vector_chunks.sql
*/

define SOURCE_LIMIT = 0
define CHUNK_CHARS = 1800
define OVERLAP_CHARS = 200

prompt ======================================================================
prompt START prepare_bank_pdf_vector_chunks.sql
prompt ======================================================================

show user

prompt Drop prior vector chunk objects if they exist...

begin
  execute immediate 'drop table BANK_PDF_VECTOR_EMBEDDINGS purge';
exception
  when others then
    if sqlcode != -942 then
      raise;
    end if;
end;
/

begin
  execute immediate 'drop table BANK_PDF_VECTOR_CHUNKS purge';
exception
  when others then
    if sqlcode != -942 then
      raise;
    end if;
end;
/

prompt Create BANK_PDF_VECTOR_CHUNKS...

create table BANK_PDF_VECTOR_CHUNKS (
  chunk_id           number generated always as identity primary key,
  statement_copy_id number not null,
  statement_id      number not null,
  copy_role         varchar2(30),
  account_no        varchar2(30),
  statement_month   date,
  file_name         varchar2(256),
  chunk_no          number not null,
  chunk_text        clob not null,
  constraint bank_pdf_vec_chunk_uk unique (statement_copy_id, chunk_no)
);

prompt Create helper functions...

create or replace function bank_pdf_blob_to_clob(p_blob in blob)
  return clob
is
  l_clob        clob;
  l_src_offset  integer := 1;
  l_dst_offset  integer := 1;
  l_lang_ctx    integer := dbms_lob.default_lang_ctx;
  l_warning     integer;
begin
  if p_blob is null then
    return null;
  end if;

  dbms_lob.createtemporary(l_clob, true);

  dbms_lob.converttoclob(
    dest_lob     => l_clob,
    src_blob     => p_blob,
    amount       => dbms_lob.lobmaxsize,
    dest_offset  => l_dst_offset,
    src_offset   => l_src_offset,
    blob_csid    => nls_charset_id('WE8ISO8859P1'),
    lang_context => l_lang_ctx,
    warning      => l_warning
  );

  return l_clob;
end;
/

create or replace function bank_pdf_unescape_text(p_text in varchar2)
  return varchar2
is
  l_out varchar2(32767) := '';
  l_pos pls_integer := 1;
  l_len pls_integer := nvl(length(p_text), 0);
  l_ch  varchar2(1);
  l_esc varchar2(1);
begin
  while l_pos <= l_len loop
    l_ch := substr(p_text, l_pos, 1);

    if l_ch != '\' then
      l_out := l_out || l_ch;
      l_pos := l_pos + 1;
    else
      l_pos := l_pos + 1;

      if l_pos > l_len then
        exit;
      end if;

      l_esc := substr(p_text, l_pos, 1);
      l_out := l_out ||
        case l_esc
          when 'n' then chr(10)
          when 'r' then chr(13)
          when 't' then chr(9)
          when 'b' then chr(8)
          when 'f' then chr(12)
          when '(' then '('
          when ')' then ')'
          when '\' then '\'
          else l_esc
        end;

      l_pos := l_pos + 1;
    end if;
  end loop;

  return l_out;
end;
/

create or replace function bank_pdf_extract_text(p_blob in blob)
  return clob
is
  l_pdf_text     clob;
  l_text         clob;
  l_pos          pls_integer := 1;
  l_tj_pos       pls_integer;
  l_window_start pls_integer;
  l_window       varchar2(32767);
  l_open_pos     pls_integer;
  l_match        varchar2(32767);
begin
  l_pdf_text := bank_pdf_blob_to_clob(p_blob);
  dbms_lob.createtemporary(l_text, true);

  loop
    l_tj_pos := dbms_lob.instr(l_pdf_text, ') Tj', l_pos, 1);
    exit when l_tj_pos = 0;

    l_window_start := greatest(1, l_tj_pos - 32760);
    l_window := dbms_lob.substr(l_pdf_text, l_tj_pos - l_window_start, l_window_start);
    l_open_pos := instr(l_window, '(', -1);

    if l_open_pos > 0 then
      l_match := trim(bank_pdf_unescape_text(substr(l_window, l_open_pos + 1)));
      if l_match is not null then
        dbms_lob.writeappend(l_text, length(l_match), l_match);
        dbms_lob.writeappend(l_text, 1, chr(10));
      end if;
    end if;

    l_pos := l_tj_pos + 4;
  end loop;

  return l_text;
end;
/

whenever sqlerror exit sql.sqlcode

prompt Extract PDF text and load vector chunks...

declare
  c_chunk_chars   constant pls_integer := &&CHUNK_CHARS;
  c_overlap_chars constant pls_integer := &&OVERLAP_CHARS;
  c_source_limit  constant pls_integer := &&SOURCE_LIMIT;

  l_text        clob;
  l_text_len    pls_integer;
  l_start       pls_integer;
  l_end         pls_integer;
  l_boundary    pls_integer;
  l_piece       varchar2(32767);
  l_chunk_no    pls_integer;
  l_pdf_rows    pls_integer := 0;
  l_chunk_rows  pls_integer := 0;
  l_empty_pdf_rows pls_integer := 0;
  l_has_file_name pls_integer := 0;
  l_sql         varchar2(32767);
  l_rc          sys_refcursor;

  l_statement_copy_id bank_pdf_deduplicate.statement_copy_id%type;
  l_statement_id      bank_pdf_deduplicate.statement_id%type;
  l_copy_role         bank_pdf_deduplicate.copy_role%type;
  l_account_no        bank_pdf_deduplicate.account_no%type;
  l_statement_month   bank_pdf_deduplicate.statement_month%type;
  l_file_name         varchar2(256);
  l_pdf_document      blob;
begin
  if c_overlap_chars >= c_chunk_chars then
    raise_application_error(-20000, 'OVERLAP_CHARS must be smaller than CHUNK_CHARS');
  end if;

  select count(*)
  into   l_has_file_name
  from   user_tab_columns
  where  table_name = 'BANK_PDF_DEDUPLICATE'
  and    column_name = 'FILE_NAME';

  l_sql :=
    'select * from (' ||
    '  select statement_copy_id,' ||
    '         statement_id,' ||
    '         copy_role,' ||
    '         account_no,' ||
    '         statement_month,' ||
    case
      when l_has_file_name > 0 then
        '         file_name,'
      else
        q'[         'statement_' || to_char(statement_id, 'FM000000') || '_' || copy_role || '.pdf' as file_name,]'
    end ||
    '         pdf_document' ||
    '  from   BANK_PDF_DEDUPLICATE' ||
    '  order  by statement_copy_id' ||
    ') where :source_limit = 0 or rownum <= :source_limit';

  open l_rc for l_sql using c_source_limit, c_source_limit;

  loop
    fetch l_rc into
      l_statement_copy_id,
      l_statement_id,
      l_copy_role,
      l_account_no,
      l_statement_month,
      l_file_name,
      l_pdf_document;

    exit when l_rc%notfound;

    l_pdf_rows := l_pdf_rows + 1;
    l_text := bank_pdf_extract_text(l_pdf_document);
    l_text_len := dbms_lob.getlength(l_text);

    if l_text_len = 0 then
      l_empty_pdf_rows := l_empty_pdf_rows + 1;
    end if;

    l_start := 1;
    l_chunk_no := 1;

    while l_start <= l_text_len loop
      l_end := least(l_start + c_chunk_chars - 1, l_text_len);

      if l_end < l_text_len then
        l_piece := dbms_lob.substr(l_text, l_end - l_start + 1, l_start);
        l_boundary := instr(l_piece, chr(10), -1);

        if l_boundary > c_chunk_chars / 2 then
          l_end := l_start + l_boundary - 1;
        end if;
      end if;

      l_piece := trim(dbms_lob.substr(l_text, l_end - l_start + 1, l_start));

      if l_piece is not null then
        insert into BANK_PDF_VECTOR_CHUNKS (
          statement_copy_id,
          statement_id,
          copy_role,
          account_no,
          statement_month,
          file_name,
          chunk_no,
          chunk_text
        ) values (
          l_statement_copy_id,
          l_statement_id,
          l_copy_role,
          l_account_no,
          l_statement_month,
          l_file_name,
          l_chunk_no,
          l_piece
        );

        l_chunk_rows := l_chunk_rows + 1;
        l_chunk_no := l_chunk_no + 1;
      end if;

      exit when l_end >= l_text_len;
      l_start := greatest(l_end - c_overlap_chars + 1, l_start + 1);
    end loop;

    if mod(l_pdf_rows, 100) = 0 then
      dbms_output.put_line('Processed ' || l_pdf_rows || ' PDFs, loaded ' || l_chunk_rows || ' chunks...');
    end if;
  end loop;

  close l_rc;

  commit;

  dbms_output.put_line('Processed PDF rows: ' || l_pdf_rows);
  dbms_output.put_line('Loaded chunk rows: ' || l_chunk_rows);
  dbms_output.put_line('PDF rows with no extracted text: ' || l_empty_pdf_rows);

  if l_pdf_rows > 0 and l_chunk_rows = 0 then
    raise_application_error(
      -20001,
      'No PDF text was extracted. The SQL demo parser only supports simple uncompressed generated PDFs with text operators such as ") Tj". Use the Python extraction path or a real PDF text extraction pipeline for these PDFs.'
    );
  end if;

  dbms_output.put_line('Next: run @bank_pdf_vector_search_setup.sql');
end;
/

prompt Vector chunk row count...

select count(*) as chunk_rows
from   BANK_PDF_VECTOR_CHUNKS;

prompt ======================================================================
prompt END prepare_bank_pdf_vector_chunks.sql
prompt ======================================================================
