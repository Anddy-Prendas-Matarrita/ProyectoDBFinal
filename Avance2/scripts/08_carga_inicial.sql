/* ============================================================================
   ENTREGABLE #2 - PARTE A - 08_carga_inicial.sql
   Carga del padron nacional. Antes: copiar DISTELEC.txt y PADRON_COMPLETO.txt a la
   carpeta de DIR_PADRON (el archivo real se baja del TSE; aqui hay uno de muestra).
   ============================================================================ */
ALTER SESSION SET CURRENT_SCHEMA = SUM_ADMIN;
SET SERVEROUTPUT ON
EXEC PKG_PADRON.P_CARGAR_TODO;
SELECT PRL_PROCESO, PRL_ESTADO, PRL_MENSAJE FROM PROCESO_LOG ORDER BY PRL_ID DESC FETCH FIRST 1 ROW ONLY;
SELECT CLI_ID, CLI_CEDULA, CLI_NOMBRE, CLI_APELLIDO1, CLI_APELLIDO2, CLI_PAD_ID FROM CLIENTE ORDER BY CLI_ID;
