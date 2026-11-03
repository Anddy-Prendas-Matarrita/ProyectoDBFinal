/* ============================================================================
   UNIVERSIDAD NACIONAL - SEDE REGIONAL BRUNCA - CAMPUS PZ/COTO
   CURSO: ADMINISTRACION DE BASE DE DATOS - II CICLO 2026
   PROYECTO FINAL - ENTREGABLE #2 - PARTE A
   ARCHIVO: 11_auditoria_bitacoras.sql   (ENTREGA 2: auditoria y bitacoras con triggers)
   ----------------------------------------------------------------------------
   ESTRATEGIA
   * AUDITORIA (tabla del Avance 1): un trigger generado automaticamente por tabla
     (TRG_AUD_xxx) registra INSERT / UPDATE (solo columnas que cambiaron) / DELETE.
     Cubre todas las tablas del Avance 1 y las nuevas de negocio.
   * Bitacoras especificas con valor anterior y nuevo: FACTURA -> BIT_FACTURACION,
     CLIENTE -> BIT_CLIENTE, PROVEEDOR -> BIT_PROVEEDOR, PROMOCION -> BIT_PROMOCION,
     DESCUENTO -> BIT_DESCUENTO. Cambios de precio (BIT_CAMBIO_PRECIO) y movimientos
     de inventario (BIT_MOV_INVENTARIO) los escriben PKG_PRECIOS y PKG_INVENTARIO.
   * Bitacora de errores (BIT_ERROR): la escribe PKG_ERRORES.
   * Las columnas de contrasena nunca se guardan en la auditoria.
   * Los triggers se GENERAN con PKG_AUDITORIA.P_GENERAR_TODOS: si se agrega una
     columna o tabla, basta volver a ejecutarlo.
   ============================================================================ */
ALTER SESSION SET CURRENT_SCHEMA = SUM_ADMIN;

CREATE OR REPLACE PACKAGE PKG_AUDITORIA AS
    PROCEDURE P_REGISTRAR (p_tabla IN VARCHAR2, p_accion IN VARCHAR2,
                           p_registro IN VARCHAR2, p_detalle IN VARCHAR2);
    PROCEDURE P_GENERAR_TRIGGER (p_tabla IN VARCHAR2, p_destino IN VARCHAR2 DEFAULT 'AUDITORIA');
    PROCEDURE P_GENERAR_TODOS;
END PKG_AUDITORIA;
/
CREATE OR REPLACE PACKAGE BODY PKG_AUDITORIA AS

    -- Escribe en AUDITORIA dentro de la transaccion de quien hizo el cambio
    PROCEDURE P_REGISTRAR (p_tabla IN VARCHAR2, p_accion IN VARCHAR2,
                           p_registro IN VARCHAR2, p_detalle IN VARCHAR2) IS
    BEGIN
        INSERT INTO AUDITORIA (AUD_TABLA, AUD_ACCION, AUD_REGISTRO, AUD_USUARIO, AUD_DETALLE)
        VALUES (SUBSTR(p_tabla, 1, 40), p_accion, SUBSTR(p_registro, 1, 50),
                PKG_UTIL.F_USUARIO_BD, SUBSTR(p_detalle, 1, 4000));
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_AUDITORIA', 'P_REGISTRAR', SQLCODE, SQLERRM, p_tabla || ' ' || p_accion);
            RAISE;
    END P_REGISTRAR;

    -- Genera el trigger de auditoria de una tabla. p_destino = 'AUDITORIA' o el nombre de una BIT_*
    PROCEDURE P_GENERAR_TRIGGER (p_tabla IN VARCHAR2, p_destino IN VARCHAR2 DEFAULT 'AUDITORIA') IS
        v_pk    VARCHAR2(30);
        v_pref  VARCHAR2(10);
        v_bp    VARCHAR2(10);
        v_nom   VARCHAR2(30);
        v_new   CLOB; v_old CLOB; v_dif CLOB; v_src CLOB;
        CRLF    CONSTANT VARCHAR2(2) := CHR(10);
    BEGIN
        SELECT cc.COLUMN_NAME INTO v_pk
          FROM USER_CONSTRAINTS c JOIN USER_CONS_COLUMNS cc ON cc.CONSTRAINT_NAME = c.CONSTRAINT_NAME
         WHERE c.TABLE_NAME = p_tabla AND c.CONSTRAINT_TYPE = 'P' AND cc.POSITION = 1;
        v_pref := SUBSTR(v_pk, 1, 3);

        v_new := ''''''; v_old := '''''';
        FOR c IN (SELECT COLUMN_NAME FROM USER_TAB_COLUMNS
                   WHERE TABLE_NAME = p_tabla AND DATA_TYPE NOT IN ('CLOB', 'BLOB', 'LONG')
                     AND COLUMN_NAME NOT LIKE '%PASSWORD%' ORDER BY COLUMN_ID) LOOP
            v_new := v_new || ' || ''' || c.COLUMN_NAME || '='' || :NEW.' || c.COLUMN_NAME || ' || '' | ''';
            v_old := v_old || ' || ''' || c.COLUMN_NAME || '='' || :OLD.' || c.COLUMN_NAME || ' || '' | ''';
            v_dif := v_dif
                || '        IF (:OLD.' || c.COLUMN_NAME || ' IS NULL AND :NEW.' || c.COLUMN_NAME || ' IS NOT NULL)' || CRLF
                || '           OR (:OLD.' || c.COLUMN_NAME || ' IS NOT NULL AND :NEW.' || c.COLUMN_NAME || ' IS NULL)' || CRLF
                || '           OR (:OLD.' || c.COLUMN_NAME || ' <> :NEW.' || c.COLUMN_NAME || ') THEN' || CRLF
                || '            v_det := v_det || ''' || c.COLUMN_NAME || ': '' || :OLD.' || c.COLUMN_NAME
                || ' || '' -> '' || :NEW.' || c.COLUMN_NAME || ' || '' | '';' || CRLF
                || '        END IF;' || CRLF;
        END LOOP;

        IF p_destino = 'AUDITORIA' THEN
            v_nom := 'TRG_AUD_' || v_pref;
            v_src := 'CREATE OR REPLACE TRIGGER ' || v_nom || CRLF
                || 'AFTER INSERT OR UPDATE OR DELETE ON ' || p_tabla || ' FOR EACH ROW' || CRLF
                || 'DECLARE v_det VARCHAR2(32767);' || CRLF
                || 'BEGIN' || CRLF
                || '    IF INSERTING THEN' || CRLF
                || '        v_det := ' || v_new || ';' || CRLF
                || '        PKG_AUDITORIA.P_REGISTRAR(''' || p_tabla || ''', ''INSERT'', TO_CHAR(:NEW.' || v_pk || '), v_det);' || CRLF
                || '    ELSIF UPDATING THEN' || CRLF
                || '        v_det := NULL;' || CRLF || v_dif
                || '        PKG_AUDITORIA.P_REGISTRAR(''' || p_tabla || ''', ''UPDATE'', TO_CHAR(:NEW.' || v_pk || '), v_det);' || CRLF
                || '    ELSE' || CRLF
                || '        v_det := ' || v_old || ';' || CRLF
                || '        PKG_AUDITORIA.P_REGISTRAR(''' || p_tabla || ''', ''DELETE'', TO_CHAR(:OLD.' || v_pk || '), v_det);' || CRLF
                || '    END IF;' || CRLF
                || 'END ' || v_nom || ';';
        ELSE
            SELECT SUBSTR(cc.COLUMN_NAME, 1, 3) INTO v_bp
              FROM USER_CONSTRAINTS c JOIN USER_CONS_COLUMNS cc ON cc.CONSTRAINT_NAME = c.CONSTRAINT_NAME
             WHERE c.TABLE_NAME = p_destino AND c.CONSTRAINT_TYPE = 'P' AND cc.POSITION = 1;
            v_nom := 'TRG_' || v_bp || '_' || v_pref;
            v_src := 'CREATE OR REPLACE TRIGGER ' || v_nom || CRLF
                || 'AFTER INSERT OR UPDATE OR DELETE ON ' || p_tabla || ' FOR EACH ROW' || CRLF
                || 'DECLARE v_ant VARCHAR2(32767); v_nue VARCHAR2(32767);' || CRLF
                || 'BEGIN' || CRLF
                || '    IF INSERTING THEN' || CRLF
                || '        v_nue := ' || v_new || ';' || CRLF
                || '        INSERT INTO ' || p_destino || ' (' || v_bp || '_REGISTRO_ID, ' || v_bp || '_ACCION, ' || v_bp || '_USUARIO, ' || v_bp || '_DATOS_ANT, ' || v_bp || '_DATOS_NUE)' || CRLF
                || '        VALUES (:NEW.' || v_pk || ', ''INSERT'', PKG_UTIL.F_USUARIO_BD, NULL, SUBSTR(v_nue, 1, 4000));' || CRLF
                || '    ELSIF UPDATING THEN' || CRLF
                || '        v_ant := ' || v_old || ';' || CRLF
                || '        v_nue := ' || v_new || ';' || CRLF
                || '        INSERT INTO ' || p_destino || ' (' || v_bp || '_REGISTRO_ID, ' || v_bp || '_ACCION, ' || v_bp || '_USUARIO, ' || v_bp || '_DATOS_ANT, ' || v_bp || '_DATOS_NUE)' || CRLF
                || '        VALUES (:NEW.' || v_pk || ', ''UPDATE'', PKG_UTIL.F_USUARIO_BD, SUBSTR(v_ant, 1, 4000), SUBSTR(v_nue, 1, 4000));' || CRLF
                || '    ELSE' || CRLF
                || '        v_ant := ' || v_old || ';' || CRLF
                || '        INSERT INTO ' || p_destino || ' (' || v_bp || '_REGISTRO_ID, ' || v_bp || '_ACCION, ' || v_bp || '_USUARIO, ' || v_bp || '_DATOS_ANT, ' || v_bp || '_DATOS_NUE)' || CRLF
                || '        VALUES (:OLD.' || v_pk || ', ''DELETE'', PKG_UTIL.F_USUARIO_BD, SUBSTR(v_ant, 1, 4000), NULL);' || CRLF
                || '    END IF;' || CRLF
                || 'END ' || v_nom || ';';
        END IF;
        EXECUTE IMMEDIATE v_src;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_AUDITORIA', 'P_GENERAR_TRIGGER', SQLCODE, SQLERRM, p_tabla || '->' || p_destino);
            RAISE;
    END P_GENERAR_TRIGGER;

    PROCEDURE P_GENERAR_TODOS IS
    BEGIN
        -- Auditoria general: todas las tablas con PK, salvo bitacoras, padron, externas y las que tienen bitacora propia
        FOR t IN (SELECT TABLE_NAME FROM USER_TABLES
                   WHERE TABLE_NAME NOT IN ('AUDITORIA', 'CLIENTE', 'PROVEEDOR', 'PROMOCION', 'DESCUENTO',
                                            'NOTIFICACION_LOG', 'PROCESO_LOG')
                     AND TABLE_NAME NOT LIKE 'BIT\_%' ESCAPE '\'
                     AND TABLE_NAME NOT LIKE 'EXT\_%' ESCAPE '\'
                     AND TABLE_NAME NOT LIKE 'PADRON\_%' ESCAPE '\'
                     AND EXISTS (SELECT 1 FROM USER_CONSTRAINTS c WHERE c.TABLE_NAME = USER_TABLES.TABLE_NAME
                                    AND c.CONSTRAINT_TYPE = 'P')
                   ORDER BY TABLE_NAME) LOOP
            P_GENERAR_TRIGGER(t.TABLE_NAME, 'AUDITORIA');
        END LOOP;
        -- Bitacoras especificas (antes / despues)
        P_GENERAR_TRIGGER('FACTURA',   'BIT_FACTURACION');
        P_GENERAR_TRIGGER('CLIENTE',   'BIT_CLIENTE');
        P_GENERAR_TRIGGER('PROVEEDOR', 'BIT_PROVEEDOR');
        P_GENERAR_TRIGGER('PROMOCION', 'BIT_PROMOCION');
        P_GENERAR_TRIGGER('DESCUENTO', 'BIT_DESCUENTO');
        -- Los criticos de cliente/proveedor tambien quedan en la auditoria general
        P_GENERAR_TRIGGER('CLIENTE',   'AUDITORIA');
        P_GENERAR_TRIGGER('PROVEEDOR', 'AUDITORIA');
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_AUDITORIA', 'P_GENERAR_TODOS', SQLCODE, SQLERRM);
            RAISE;
    END P_GENERAR_TODOS;
END PKG_AUDITORIA;
/
SHOW ERRORS

-- Genera todos los triggers de auditoria y bitacoras
EXEC PKG_AUDITORIA.P_GENERAR_TODOS;

-- Verificacion: triggers generados (deben estar todos VALID / ENABLED)
SELECT TRIGGER_NAME, TABLE_NAME, STATUS FROM USER_TRIGGERS
 WHERE TRIGGER_NAME LIKE 'TRG\_AUD\_%' ESCAPE '\' OR TRIGGER_NAME IN ('TRG_BFA_FAC','TRG_BCL_CLI','TRG_BPV_PRV','TRG_BPM_PRM','TRG_BDS_DES')
 ORDER BY TABLE_NAME;
SELECT OBJECT_NAME, OBJECT_TYPE FROM USER_OBJECTS WHERE STATUS = 'INVALID';

/* ============================== FIN DEL SCRIPT ============================== */
