/* ============================================================================
   ENTREGABLE #2 - 16_instalar_todo.sql
   Instalacion completa en el orden unico de ejecucion (Parte A).
   USO: abrir SQL*Plus EN LA CARPETA donde estan los scripts, conectado como
        SYSTEM al PDB (FREEPDB1 / XEPDB1) y ejecutar:  @16_instalar_todo.sql
   Antes: copiar DISTELEC.txt y PADRON_COMPLETO.txt a la carpeta de DIR_PADRON
          y ajustar la ruta del directorio en 00_prerequisitos_DBA.sql.
   Los tablespaces y el usuario SUM_ADMIN NO necesitan existir: los crea el paso 1.
   ============================================================================ */
SET ECHO ON SERVEROUTPUT ON LINESIZE 200 PAGESIZE 100
SPOOL instalacion_entrega2.log

-- Paso 1 (SYSTEM): tablespaces, usuario SUM_ADMIN y estructura del Avance 1
@01_script_completo.sql
-- Paso 2 (SYSTEM): privilegios de la Parte A y directorio del padron
@00_prerequisitos_DBA.sql

-- Desde aqui como SUM_ADMIN (clave definida en la seccion 2 del script 01)
ACCEPT servicio PROMPT 'Servicio del PDB (ej. localhost:1521/FREEPDB1): '
ACCEPT clave PROMPT 'Clave de SUM_ADMIN: ' HIDE
CONNECT sum_admin/&clave@//&servicio

@05_modelo_entregable2.sql
@06_paquetes_base.sql
@07_triggers_negocio.sql
@08_carga_inicial.sql
@10_paquetes_procesos.sql
@11_auditoria_bitacoras.sql
@12_vistas_materializadas.sql
@14_jobs_parteA.sql

PROMPT ----- Objetos invalidos (debe devolver 0 filas) -----
SELECT OBJECT_NAME, OBJECT_TYPE FROM USER_OBJECTS WHERE STATUS = 'INVALID';
SPOOL OFF
-- Pruebas (opcionales, ejecutar bloque por bloque): @09_pruebas_entrega1.sql  @15_pruebas_entrega2.sql
-- Analisis de costos: @13_explain_plan.sql
