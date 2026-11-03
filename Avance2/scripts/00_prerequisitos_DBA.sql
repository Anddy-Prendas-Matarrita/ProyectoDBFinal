/* ============================================================================
   ENTREGABLE #2 - PARTE A - 00_prerequisitos_DBA.sql
   Ejecutar como SYSTEM / SYS AS SYSDBA conectado al PDB (FREEPDB1 / XEPDB1).
   Otorga al esquema SUM_ADMIN SOLO los privilegios que necesita la Parte A
   (privilegios de sistema minimos, sin DBA). La seguridad completa (perfiles,
   roles, usuarios) la implementa la Parte B.
   ============================================================================ */
GRANT CREATE MATERIALIZED VIEW TO SUM_ADMIN;
GRANT CREATE JOB               TO SUM_ADMIN;
GRANT CREATE TABLE             TO SUM_ADMIN;
GRANT CREATE TYPE              TO SUM_ADMIN;
GRANT CREATE ANY DIRECTORY     TO SYSTEM;
GRANT SELECT ON DBA_TABLESPACE_USAGE_METRICS TO SUM_ADMIN;
GRANT EXECUTE ON DBMS_CRYPTO   TO SUM_ADMIN;

-- Directorio donde se coloca el archivo del padron (ajustar la ruta del servidor).
-- Linux  : /opt/oracle/padron      Windows: C:\oracle\padron
CREATE OR REPLACE DIRECTORY DIR_PADRON AS 'C:\oracle\padron';
GRANT READ, WRITE ON DIRECTORY DIR_PADRON TO SUM_ADMIN;
