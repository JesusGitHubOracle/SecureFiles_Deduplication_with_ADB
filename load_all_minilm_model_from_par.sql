set echo on
set serveroutput on size unlimited
set define on
set linesize 220
set pagesize 100

/*
  Load the augmented all-MiniLM-L12-v2 ONNX embedding model into Autonomous
  Database from an OCI Object Storage PAR URL.

  Run as YOUR_SCHEMA after the user has permission to create mining models and
  execute DBMS_VECTOR.

  ADMIN grants:

    grant create mining model to YOUR_SCHEMA;
    grant execute on DBMS_VECTOR to YOUR_SCHEMA;
*/

define MODEL_NAME = 'ALL_MINILM_L12_V2'
define MODEL_URI = '<oci-object-storage-par-url-for-all_MiniLM_L12_V2.onnx>'

prompt ======================================================================
prompt START load_all_minilm_model_from_par.sql
prompt ======================================================================

show user

prompt Existing models before load...

column model_name format a40
column mining_function format a24
column algorithm format a32

select model_name, mining_function, algorithm
from   user_mining_models
order  by model_name;

prompt Drop existing model with the same name, if present...

begin
  dbms_data_mining.drop_model(
    model_name => replace(q'[&&MODEL_NAME]', '''', ''),
    force      => true
  );
exception
  when others then
    if sqlcode != -40102 then
      raise;
    end if;
end;
/

prompt Load ONNX embedding model from PAR URL...

begin
  dbms_vector.load_onnx_model_cloud(
    model_name => replace(q'[&&MODEL_NAME]', '''', ''),
    credential => null,
    uri        => replace(q'[&&MODEL_URI]', '''', ''),
    metadata   => json('{
      "function": "embedding",
      "embeddingOutput": "embedding",
      "input": { "input": ["DATA"] }
    }')
  );
end;
/

prompt Verify model registration...

select model_name, mining_function, algorithm
from   user_mining_models
where  model_name = replace(q'[&&MODEL_NAME]', '''', '');

prompt Smoke test VECTOR_EMBEDDING...

select vector_embedding(
         &&MODEL_NAME
         using 'Oracle Database supports vector search.' as data
       ) as embedding
from dual;

prompt ======================================================================
prompt END load_all_minilm_model_from_par.sql
prompt ======================================================================
