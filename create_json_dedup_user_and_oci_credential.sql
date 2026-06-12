-- create_json_dedup_user_and_oci_credential.sql
--
-- Run this as ADMIN, SYSTEM, or another privileged database account.
-- It creates the demo schema used by the SecureFiles deduplication and
-- Oracle AI Vector Search demo scripts, then shows how to create an OCI
-- Object Storage credential for model/data loading.

set define on
set verify off
set serveroutput on

define DEMO_USER = JSON_DEDUP
define DEMO_PASSWORD = "ChangeThisPassword_12345"
define DEFAULT_TABLESPACE = DATA
define TEMP_TABLESPACE = TEMP

prompt Creating or updating &&DEMO_USER...

declare
  l_count number;
begin
  select count(*)
  into   l_count
  from   dba_users
  where  username = upper('&&DEMO_USER');

  if l_count = 0 then
    execute immediate
      'create user &&DEMO_USER identified by &&DEMO_PASSWORD ' ||
      'default tablespace &&DEFAULT_TABLESPACE temporary tablespace &&TEMP_TABLESPACE';
  else
    execute immediate
      'alter user &&DEMO_USER identified by &&DEMO_PASSWORD account unlock';
  end if;
end;
/

alter user &&DEMO_USER quota unlimited on &&DEFAULT_TABLESPACE;

prompt Granting base demo privileges...

grant create session to &&DEMO_USER;
grant create table to &&DEMO_USER;
grant create view to &&DEMO_USER;
grant create sequence to &&DEMO_USER;
grant create procedure to &&DEMO_USER;
grant create trigger to &&DEMO_USER;
grant create type to &&DEMO_USER;

-- Needed by the vector demo to import ONNX embedding models into the schema.
grant create mining model to &&DEMO_USER;

-- Needed by the vector demo scripts that call DBMS_VECTOR.LOAD_ONNX_MODEL_CLOUD.
grant execute on dbms_vector to &&DEMO_USER;

-- Needed only when the schema itself creates/uses OCI Object Storage credentials
-- with DBMS_CLOUD. Autonomous Database normally exposes DBMS_CLOUD, but explicit
-- execute grants are harmless when run by ADMIN and useful for cloned/nonstandard
-- environments.
grant execute on dbms_cloud to &&DEMO_USER;

prompt
prompt Optional: grant read/write on an existing DIRECTORY object if your demo
prompt imports local files through database directory objects.
prompt Example:
prompt   grant read, write on directory DATA_PUMP_DIR to &&DEMO_USER;
prompt

prompt Creating helper role for repeatable demo grants...

declare
  l_count number;
begin
  select count(*)
  into   l_count
  from   dba_roles
  where  role = 'SECUREFILES_VECTOR_DEMO_ROLE';

  if l_count = 0 then
    execute immediate 'create role securefiles_vector_demo_role';
  end if;
end;
/

grant create session to securefiles_vector_demo_role;
grant create table to securefiles_vector_demo_role;
grant create view to securefiles_vector_demo_role;
grant create sequence to securefiles_vector_demo_role;
grant create procedure to securefiles_vector_demo_role;
grant create trigger to securefiles_vector_demo_role;
grant create type to securefiles_vector_demo_role;
grant create mining model to securefiles_vector_demo_role;
grant securefiles_vector_demo_role to &&DEMO_USER;

prompt
prompt User &&DEMO_USER is ready for the SecureFiles and vector search demos.
prompt

prompt ================================================================
prompt OCI Object Storage credential setup
prompt ================================================================
prompt
prompt Choose ONE of the credential approaches below.
prompt
prompt A) Public PAR URL:
prompt    If your Object Storage file is available through a pre-authenticated
prompt    request URL, the vector model loader can usually use credential => null.
prompt    No DBMS_CLOUD credential is required.
prompt
prompt B) OCI Auth Token credential:
prompt    Use this for private Object Storage access with username/password-style
prompt    authentication. The password value is an OCI Auth Token, not your OCI
prompt    console password.
prompt
prompt    Steps:
prompt      1. In OCI Console, open the user profile that owns/reads the bucket.
prompt      2. Create or copy an Auth Token.
prompt      3. Connect as &&DEMO_USER.
prompt      4. Run the block below with your OCI username and Auth Token.
prompt
prompt    begin
prompt      dbms_cloud.create_credential(
prompt        credential_name => 'OCI_OBJECT_STORAGE_CRED',
prompt        username        => '<oci-user-name-or-email>',
prompt        password        => '<oci-auth-token>'
prompt      );
prompt    end;
prompt    /
prompt
prompt    Test:
prompt      select object_name, bytes
prompt      from   dbms_cloud.list_objects(
prompt               'OCI_OBJECT_STORAGE_CRED',
prompt               'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/'
prompt             );
prompt
prompt C) OCI Native API-signing-key credential:
prompt    Use this for private Object Storage access when you prefer API keys.
prompt    You need the OCI user OCID, tenancy OCID, private key, and fingerprint.
prompt
prompt    Steps:
prompt      1. Generate/upload an OCI API signing public key for the OCI user.
prompt      2. Copy the private key body, user OCID, tenancy OCID, and fingerprint.
prompt      3. Connect as &&DEMO_USER.
prompt      4. Run the block below.
prompt
prompt    begin
prompt      dbms_cloud.create_credential(
prompt        credential_name => 'OCI_NATIVE_CRED',
prompt        user_ocid       => '<ocid1.user.oc1..xxxx>',
prompt        tenancy_ocid    => '<ocid1.tenancy.oc1..xxxx>',
prompt        private_key     => '<private-key-body-without-BEGIN-END-lines>',
prompt        fingerprint     => '<api-key-fingerprint>'
prompt      );
prompt    end;
prompt    /
prompt
prompt    Test:
prompt      select object_name, bytes
prompt      from   dbms_cloud.list_objects(
prompt               'OCI_NATIVE_CRED',
prompt               'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/'
prompt             );
prompt
prompt For the vector model loader, use the credential name in:
prompt   dbms_vector.load_onnx_model_cloud(
prompt     model_name => 'ALL_MINILM_L12_V2',
prompt     credential => 'OCI_OBJECT_STORAGE_CRED',
prompt     uri        => 'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/all_MiniLM_L12_v2.onnx',
prompt     metadata   => json('{"function":"embedding","embeddingOutput":"embedding","input":{"input":["DATA"]}}')
prompt   );
prompt
