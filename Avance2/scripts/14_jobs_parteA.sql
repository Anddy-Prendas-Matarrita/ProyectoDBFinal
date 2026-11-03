/* ============================================================================
   ENTREGABLE #2 - PARTE A - 14_jobs_parteA.sql
   Jobs de DBMS_SCHEDULER de la logica de negocio (Parte A). La Parte B puede
   ejecutar este mismo script o registrar los jobs con la tabla de la seccion 3.
   Hora del servidor: DBMS_SCHEDULER usa la zona horaria de la sesion/DB.
   ============================================================================ */
ALTER SESSION SET CURRENT_SCHEMA = SUM_ADMIN;

CREATE OR REPLACE PROCEDURE P_CREAR_JOBS_NEGOCIO IS
    PROCEDURE P_JOB (p_nombre VARCHAR2, p_accion VARCHAR2, p_intervalo VARCHAR2, p_comentario VARCHAR2) IS
    BEGIN
        BEGIN
            DBMS_SCHEDULER.DROP_JOB(job_name => p_nombre, force => TRUE);
        EXCEPTION
            WHEN OTHERS THEN NULL;                    -- el job aun no existe
        END;
        DBMS_SCHEDULER.CREATE_JOB(
            job_name        => p_nombre,
            job_type        => 'STORED_PROCEDURE',
            job_action      => p_accion,
            start_date      => SYSTIMESTAMP,
            repeat_interval => p_intervalo,
            enabled         => TRUE,
            auto_drop       => FALSE,
            comments        => p_comentario);
    END P_JOB;
BEGIN
    P_JOB('JOB_CIERRE_DIARIO',        'PKG_CIERRE.P_CIERRE_DIARIO',                 'FREQ=DAILY;BYHOUR=23;BYMINUTE=55', 'Cierre diario; notifica a coordinador y gerente');
    P_JOB('JOB_MERCADEO_SEMANAL',     'PKG_MERCADEO.P_REPORTE_SEMANAL',             'FREQ=WEEKLY;BYDAY=MON;BYHOUR=6',   'Productos por vencer (7 dias) y con mas de 6 meses en bodega');
    P_JOB('JOB_DESCUENTOS_SEMANAL',   'PKG_DESCUENTOS.P_APLICAR_PROGRAMADOS',       'FREQ=WEEKLY;BYDAY=MON;BYHOUR=5',   'Incluye productos en descuentos planeados (vencimiento/antiguedad)');
    P_JOB('JOB_VENCIDOS_DIARIO',      'PKG_MERCADEO.P_NOTIFICAR_VENCIDOS',          'FREQ=DAILY;BYHOUR=7',              'Lista de productos vencidos con total');
    P_JOB('JOB_PREMIOS_CLIENTES',     'PKG_PREMIOS.P_PREMIAR_MEJORES_CLIENTES',     'FREQ=DAILY;BYHOUR=1',              'Corre a diario y se auto-controla: solo premia cada FRECUENCIA_PREMIOS_MESES');
    P_JOB('JOB_NOTIF_CREDITO_DIARIO', 'PKG_NOTIFICACIONES.P_EJECUTAR_TODAS',       'FREQ=DAILY;BYHOUR=8',              'Limites de credito (clientes/proveedores) y morosos');
    P_JOB('JOB_REFRESCAR_MV',         'PKG_REPORTES.P_REFRESCAR_MV',                'FREQ=DAILY;BYHOUR=0;BYMINUTE=30',  'Refresca vistas materializadas');
    P_JOB('JOB_PADRON_MENSUAL',       'PKG_PADRON.P_CARGAR_TODO',                   'FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=3','Recarga del padron nacional y enlace con clientes');
END P_CREAR_JOBS_NEGOCIO;
/
SHOW ERRORS
EXEC P_CREAR_JOBS_NEGOCIO;

-- Verificacion
SELECT JOB_NAME, ENABLED, STATE, REPEAT_INTERVAL, NEXT_RUN_DATE FROM USER_SCHEDULER_JOBS ORDER BY JOB_NAME;
-- Historial de ejecuciones del scheduler
SELECT JOB_NAME, STATUS, ACTUAL_START_DATE, ERRORS FROM USER_SCHEDULER_JOB_RUN_DETAILS ORDER BY LOG_ID DESC FETCH FIRST 20 ROWS ONLY;
-- Ejecucion manual (para la defensa):  EXEC DBMS_SCHEDULER.RUN_JOB('JOB_CIERRE_DIARIO');
