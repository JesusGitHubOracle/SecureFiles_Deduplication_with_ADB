


/* For a realistic bank use case, model duplicate storage like this:

one generated monthly PDF statement
same exact PDF stored as online statement copy
same exact PDF stored as compliance/archive copy
optionally same exact PDF stored as customer service/reprint copy
That should give ratios around 2, 3, or 4.

*/

set serveroutput on
set linesize 220
set pagesize 100


prompt Actual dedup ratio from allocated SecureFiles LOB segment bytes...

column metric format a45
column value format a30

with lob_segments as (
  select l.table_name,
         s.bytes
  from user_lobs l
  join user_segments s
    on s.segment_name = l.segment_name
  where l.table_name in ('BANK_PDF_KEEP_DUPLICATES', 'BANK_PDF_DEDUPLICATE')
  and   l.column_name = 'PDF_DOCUMENT'
),
summary as (
  select
    max(case when table_name = 'BANK_PDF_KEEP_DUPLICATES' then bytes end) as keep_bytes,
    max(case when table_name = 'BANK_PDF_DEDUPLICATE' then bytes end) as dedup_bytes
  from lob_segments
)
select 'KEEP_DUPLICATES allocated MB' as metric,
       to_char(round(keep_bytes / 1024 / 1024, 2)) as value
from summary
union all
select 'DEDUPLICATE allocated MB',
       to_char(round(dedup_bytes / 1024 / 1024, 2))
from summary
union all
select 'Actual dedup ratio',
       to_char(round(keep_bytes / nullif(dedup_bytes, 0), 2))
from summary;

/*
Actual dedup ratio from allocated SecureFiles LOB segment bytes...

METRIC                                        VALUE                         
--------------------------------------------- ------------------------------
KEEP_DUPLICATES allocated MB                  504.25                        
DEDUPLICATE allocated MB                      256.25                        
Actual dedup ratio                            1.97          

Meaning: the non-deduplicated SecureFiles LOB segment allocated about 2.78x as much space as the deduplicated one. 
Put another way, deduplication reduced the LOB segment allocation by roughly:

1 - (112.25 / 312.25) = 64.05%


*/