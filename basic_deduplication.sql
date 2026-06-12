

/*
    Basic Deduplication Example
    ----------------------------        
    This script demonstrates the basic deduplication feature of Oracle SecureFiles LOBs.
    It creates two tables with identical CLOB data, one with deduplication enabled and one without, and compares their storage usage.      
    Note: The actual deduplication ratio and storage savings may vary based on the data and Oracle version. This example uses synthetic data for demonstration purposes.
    
    */


set serveroutput on
set linesize 200
set pagesize 100

prompt Cleanup from prior run...

begin
  execute immediate 'drop table sf_keep_duplicates purge';
exception
  when others then
    if sqlcode != -942 then raise; end if;
end;
/

begin
  execute immediate 'drop table sf_deduplicate purge';
exception
  when others then
    if sqlcode != -942 then raise; end if;
end;
/

prompt Create SecureFiles LOB tables...

-- Note: The "keep_duplicates" and "deduplicate" storage parameters control whether identical LOB data is stored once or multiple times.

create table sf_keep_duplicates (
  id      number primary key,
  payload clob
)
lob (payload) store as securefile (
  keep_duplicates
  nocompress
  nocache
  logging
);

create table sf_deduplicate (
  id      number primary key,
  payload clob
)
lob (payload) store as securefile (
  deduplicate
  nocompress
  nocache
  logging
);

prompt Insert identical large CLOBs into both tables...
/*
 Oracle generates 1000 rows from the single row in p. The CLOB data is identical for all rows, which allows us to see the effect of deduplication in the second table.
 The "payload" CLOB is approximately 131 KB in size (4 * 32,767 bytes) and is repeated 1000 times, resulting in about 131 MB of logical LOB data for each table.
*/
insert into sf_keep_duplicates (id, payload)
with p as (
  select
      to_clob(rpad('A', 32767, 'A')) ||
      to_clob(rpad('B', 32767, 'B')) ||
      to_clob(rpad('C', 32767, 'C')) ||
      to_clob(rpad('D', 32767, 'D')) as payload
  from dual
)
select level, p.payload
from p
connect by level <= 1000;


insert into sf_deduplicate (id, payload)
with p as (
  select
      to_clob(rpad('A', 32767, 'A')) ||
      to_clob(rpad('B', 32767, 'B')) ||
      to_clob(rpad('C', 32767, 'C')) ||
      to_clob(rpad('D', 32767, 'D')) as payload
  from dual
)
select level, p.payload
from p
connect by level <= 1000;

commit;

prompt Show LOB settings...
/*
 The "deduplication" column indicates whether deduplication is enabled for the LOB column. 
 The "securefile" column indicates that the LOB is stored as a SecureFile.
 */

column table_name format a25
column column_name format a20
column segment_name format a35
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
where table_name in ('SF_KEEP_DUPLICATES', 'SF_DEDUPLICATE')
order by table_name;


/* sample output:
Show LOB settings...

TABLE_NAME                COLUMN_NAME          SEGMENT_NAME                        SECUREFILE DEDUPLICATION   COMPRESSION 
------------------------- -------------------- ----------------------------------- ---------- --------------- ------------
SF_DEDUPLICATE            PAYLOAD              SYS_LOB0000264930C00002$$           YES        LOB             NO          
SF_KEEP_DUPLICATES        PAYLOAD              SYS_LOB0000264926C00002$$           YES        NO              NO          

*/




prompt Compare LOB segment allocation...
/*
Compare LOB segment allocation...

The USER_SEGMENTS comparison measures allocated LOB segment space. This
includes SecureFiles metadata, extent allocation, LOB index/locator structures,
and other storage overhead, so the observed allocated-space ratio is lower.
The "mb" column shows the size of the LOB segment in megabytes, 
which should be significantly smaller for the deduplicated table compared to the non-deduplicated table.
*/

column segment_name format a35
column mb format 999,999,990.00

select l.table_name,
       l.deduplication,
       s.segment_name,
       s.segment_type,
       round(s.bytes / 1024 / 1024, 2) as mb
  from user_lobs l
  join user_segments s
  on s.segment_name = l.segment_name
where l.table_name in ('SF_KEEP_DUPLICATES', 'SF_DEDUPLICATE')
order by l.table_name;

/*
TABLE_NAME                DEDUPLICATION   SEGMENT_NAME                        SEGMENT_TYPE                    MB
------------------------- --------------- ----------------------------------- ------------------ ---------------
SF_DEDUPLICATE            LOB             SYS_LOB0000264930C00002$$           LOBSEGMENT                    1.25
SF_KEEP_DUPLICATES        NO              SYS_LOB0000264926C00002$$           LOBSEGMENT                  288.25
*/


prompt Validate row counts and logical CLOB sizes are the same...
/*
The "rows_inserted" column confirms that both tables have the same number of rows (1000),
and the "min_lob_length" and "max_lob_length" columns confirm that the logical size of the CLOB data is the same
for both tables (approximately 131 KB per row).
*/
select 'SF_KEEP_DUPLICATES' as table_name,
       count(*) as rows_inserted,
       min(dbms_lob.getlength(payload)) as min_lob_length,
       max(dbms_lob.getlength(payload)) as max_lob_length
from sf_keep_duplicates
union all
select 'SF_DEDUPLICATE',
       count(*),
       min(dbms_lob.getlength(payload)),
       max(dbms_lob.getlength(payload))
from sf_deduplicate;

/* sample output:
TABLE_NAME                ROWS_INSERTED MIN_LOB_LENGTH MAX_LOB_LENGTH
------------------------- ------------- -------------- --------------
SF_KEEP_DUPLICATES                 1000         131068         131068
SF_DEDUPLICATE                     1000         131068         131068
*/


prompt Optional: show approximate deduplication ratio.
/* 
Note:
DBMS_SECUREFILES.GET_LOB_DEDUPLICATION_RATIO estimates duplicate-content
opportunity. It is not the same as the actual allocated segment-space ratio.

In this  example, 1000 identical CLOBs produce an estimated deduplication ratio of 1000:1.
This means that logically, the 1000 identical CLOBs could be stored as 1 unique CLOB, resulting in a 1000:1 logical-to-deduplicated storage ratio for the sampled LOBs.
The actual allocated segment ratio is lower, about 230:1, because database segments still have metadata and allocation overhead.
*/
declare
  l_tablespace_name user_lobs.tablespace_name%type;
  l_dedup_ratio     number;
  l_return_value    number;
begin
  select tablespace_name
  into   l_tablespace_name
  from   user_lobs
  where  table_name = 'SF_KEEP_DUPLICATES'
  and    column_name = 'PAYLOAD';

  l_return_value := dbms_securefiles.get_lob_deduplication_ratio(
                      l_tablespace_name,
                      user,
                      'SF_KEEP_DUPLICATES',
                      'PAYLOAD',
                      null,
                      l_dedup_ratio,
                      -1
                    );

  dbms_output.put_line('Estimated deduplication ratio: ' || l_dedup_ratio);
  dbms_output.put_line('Function return value: ' || l_return_value);
end;
/

/* sample output:
 Estimated deduplication ratio: 1000
 1000:1 logical-to-deduplicated storage ratio for the sampled LOBs.
 1000 identical copies / 1 stored copy
*/