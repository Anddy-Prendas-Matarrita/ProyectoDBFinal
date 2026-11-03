/* ============================================================================
   UNIVERSIDAD NACIONAL - SEDE REGIONAL BRUNCA - CAMPUS PZ/COTO
   CURSO: ADMINISTRACION DE BASE DE DATOS - II CICLO 2026
   PROYECTO FINAL - ENTREGABLE #2 - PARTE A
   ARCHIVO: 06_paquetes_base.sql   (ENTREGA 1: paquetes base y de negocio)
   ----------------------------------------------------------------------------
   MODULOS (cada uno es un paquete con procedimientos y/o funciones):
     PKG_ERRORES      Bitacora de errores (transaccion autonoma)
     PKG_PARAMETROS   Lectura de la tabla PARAMETRO
     PKG_UTIL         Utilidades (usuario actual, bloqueos, formato de montos)
     PKG_PADRON       Carga automatica del padron nacional y enlace con CLIENTE
     PKG_INVENTARIO   Existencias central/sucursal + bitacora de movimientos
     PKG_PRECIOS      Historial automatico de precios
     PKG_CUENTAS      Cuentas por cobrar / por pagar, limites de credito, abonos
     PKG_COMPRAS      Facturas de proveedor y devoluciones a proveedor
     PKG_FACTURACION  Facturas a clientes, anulacion y notas de credito
   CONVENCIONES DE CODIGO:
     * Todo procedimiento/funcion tiene bloque EXCEPTION que registra en BIT_ERROR.
     * Las operaciones criticas "publicas" usan SAVEPOINT + COMMIT / ROLLBACK TO.
     * Los procedimientos que invocan los triggers NO hacen COMMIT ni ROLLBACK
       (la transaccion la controla quien ejecuta el DML).
     * Concurrencia: SELECT FOR UPDATE (cuentas), FOR UPDATE WAIT n
       (inventario, limites; n sale de PARAMETRO) y FOR UPDATE NOWAIT (anulacion).
   Codigos de error de negocio (RAISE_APPLICATION_ERROR):
     -20101 cliente no preferencial       -20102 limite de credito del cliente
     -20103 cliente inactivo              -20111 limite de credito del proveedor
     -20112 proveedor inactivo            -20121 stock insuficiente
     -20141 cuenta no admite abonos       -20142 abono mayor al saldo
     -20150 parametro invalido            -20161 compra invalida
     -20170/-20171/-20172 facturacion     -20173/-20174 anulacion
     -20175 devolucion excede lo facturado -20176 transicion de estado invalida
     -20190 recurso bloqueado por otra sesion
   ============================================================================ */
ALTER SESSION SET CURRENT_SCHEMA = SUM_ADMIN;

/* ============================================================================
   PKG_ERRORES  -  bitacora de errores
   P_REGISTRAR usa PRAGMA AUTONOMOUS_TRANSACTION: el error queda guardado aunque
   la transaccion principal haga ROLLBACK.
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_ERRORES AS
    PROCEDURE P_REGISTRAR (p_modulo   IN VARCHAR2,
                           p_objeto   IN VARCHAR2,
                           p_codigo   IN NUMBER,
                           p_mensaje  IN VARCHAR2,
                           p_contexto IN VARCHAR2 DEFAULT NULL);
END PKG_ERRORES;
/
CREATE OR REPLACE PACKAGE BODY PKG_ERRORES AS
    -- Evita registrar dos veces el mismo error cuando sube por varios niveles de llamadas
    g_ultima_clave  VARCHAR2(400);
    g_ultima_fecha  DATE;

    PROCEDURE P_REGISTRAR (p_modulo   IN VARCHAR2,
                           p_objeto   IN VARCHAR2,
                           p_codigo   IN NUMBER,
                           p_mensaje  IN VARCHAR2,
                           p_contexto IN VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_clave VARCHAR2(400);
    BEGIN
        v_clave := p_codigo || '|' || SUBSTR(p_mensaje, 1, 300);
        IF g_ultima_clave = v_clave AND g_ultima_fecha IS NOT NULL
           AND (SYSDATE - g_ultima_fecha) < (5 / 86400) THEN
            RETURN;                                   -- ya registrado hace instantes
        END IF;
        INSERT INTO BIT_ERROR (BER_USUARIO, BER_MODULO, BER_OBJETO, BER_CODIGO,
                               BER_MENSAJE, BER_TRAZA, BER_CONTEXTO)
        VALUES (SUBSTR(SYS_CONTEXT('USERENV','SESSION_USER'), 1, 30),
                SUBSTR(p_modulo, 1, 30), SUBSTR(p_objeto, 1, 60), p_codigo,
                SUBSTR(p_mensaje, 1, 4000),
                SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000),
                SUBSTR(p_contexto, 1, 1000));
        COMMIT;
        g_ultima_clave := v_clave;
        g_ultima_fecha := SYSDATE;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;     -- la bitacora nunca debe interrumpir el proceso que la invoco
    END P_REGISTRAR;
END PKG_ERRORES;
/

/* ============================================================================
   PKG_PARAMETROS  -  acceso a la tabla PARAMETRO (todo lo "parametrizado")
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_PARAMETROS AS
    FUNCTION  F_VALOR  (p_codigo IN VARCHAR2, p_defecto IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2;
    FUNCTION  F_NUMERO (p_codigo IN VARCHAR2, p_defecto IN NUMBER   DEFAULT NULL) RETURN NUMBER;
    PROCEDURE P_ACTUALIZAR (p_codigo IN VARCHAR2, p_valor IN VARCHAR2);
END PKG_PARAMETROS;
/
CREATE OR REPLACE PACKAGE BODY PKG_PARAMETROS AS

    FUNCTION F_VALOR (p_codigo IN VARCHAR2, p_defecto IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
        v_valor PARAMETRO.PAR_VALOR%TYPE;
    BEGIN
        SELECT PAR_VALOR INTO v_valor
          FROM PARAMETRO
         WHERE PAR_CODIGO = UPPER(p_codigo) AND PAR_ESTADO = 'A';
        RETURN v_valor;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN p_defecto;                      -- parametro inexistente: valor por defecto
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_PARAMETROS', 'F_VALOR', SQLCODE, SQLERRM, p_codigo);
            RAISE;
    END F_VALOR;

    FUNCTION F_NUMERO (p_codigo IN VARCHAR2, p_defecto IN NUMBER DEFAULT NULL) RETURN NUMBER IS
        v_txt VARCHAR2(500);
    BEGIN
        v_txt := F_VALOR(p_codigo);
        IF v_txt IS NULL THEN
            RETURN p_defecto;
        END IF;
        RETURN TO_NUMBER(v_txt, '9999999999999.99', 'NLS_NUMERIC_CHARACTERS=''.,''');
    EXCEPTION
        WHEN VALUE_ERROR OR INVALID_NUMBER THEN
            PKG_ERRORES.P_REGISTRAR('PKG_PARAMETROS', 'F_NUMERO', SQLCODE,
                                    'El parametro ' || p_codigo || ' no es numerico: ' || v_txt, p_codigo);
            RAISE_APPLICATION_ERROR(-20150, 'El parametro ' || p_codigo || ' no es numerico.');
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_PARAMETROS', 'F_NUMERO', SQLCODE, SQLERRM, p_codigo);
            RAISE;
    END F_NUMERO;

    -- Cambia el valor de un parametro (operacion critica: savepoint + commit/rollback)
    PROCEDURE P_ACTUALIZAR (p_codigo IN VARCHAR2, p_valor IN VARCHAR2) IS
    BEGIN
        SAVEPOINT sp_par_actualizar;
        UPDATE PARAMETRO SET PAR_VALOR = p_valor WHERE PAR_CODIGO = UPPER(p_codigo);
        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20150, 'El parametro ' || p_codigo || ' no existe.');
        END IF;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_par_actualizar;
            PKG_ERRORES.P_REGISTRAR('PKG_PARAMETROS', 'P_ACTUALIZAR', SQLCODE, SQLERRM,
                                    p_codigo || '=' || p_valor);
            RAISE;
    END P_ACTUALIZAR;
END PKG_PARAMETROS;
/

/* ============================================================================
   PKG_UTIL  -  utilidades comunes
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_UTIL AS
    FUNCTION F_USUARIO_BD        RETURN VARCHAR2;
    FUNCTION F_USUARIO_APP       RETURN NUMBER;
    FUNCTION F_ESPERA_BLOQUEO    RETURN PLS_INTEGER;
    FUNCTION F_MONTO (p_monto IN NUMBER) RETURN VARCHAR2;
END PKG_UTIL;
/
CREATE OR REPLACE PACKAGE BODY PKG_UTIL AS

    -- Usuario de base de datos conectado (para las bitacoras)
    FUNCTION F_USUARIO_BD RETURN VARCHAR2 IS
    BEGIN
        RETURN SUBSTR(SYS_CONTEXT('USERENV','SESSION_USER'), 1, 30);
    END F_USUARIO_BD;

    -- USR_ID de la tabla USUARIO que corresponde al usuario de BD; si no existe usa el de sistema
    FUNCTION F_USUARIO_APP RETURN NUMBER IS
        v_id USUARIO.USR_ID%TYPE;
    BEGIN
        SELECT USR_ID INTO v_id
          FROM USUARIO
         WHERE UPPER(USR_LOGIN) = UPPER(SYS_CONTEXT('USERENV','SESSION_USER'))
           AND USR_ESTADO = 'A';
        RETURN v_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN PKG_PARAMETROS.F_NUMERO('USR_ID_SISTEMA', 1);
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_UTIL', 'F_USUARIO_APP', SQLCODE, SQLERRM);
            RAISE;
    END F_USUARIO_APP;

    -- Segundos a esperar en SELECT ... FOR UPDATE WAIT n (parametro INV_LOCK_WAIT_SEG)
    FUNCTION F_ESPERA_BLOQUEO RETURN PLS_INTEGER IS
    BEGIN
        RETURN TRUNC(NVL(PKG_PARAMETROS.F_NUMERO('INV_LOCK_WAIT_SEG', 5), 5));
    END F_ESPERA_BLOQUEO;

    -- Formato de monto para los correos: 1,234,567.89
    FUNCTION F_MONTO (p_monto IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TRIM(TO_CHAR(NVL(p_monto, 0), 'FM999G999G999G999G990D00',
                            'NLS_NUMERIC_CHARACTERS=''.,'''));
    EXCEPTION
        WHEN OTHERS THEN
            RETURN TO_CHAR(p_monto);
    END F_MONTO;
END PKG_UTIL;
/

/* ============================================================================
   PKG_PADRON  -  carga automatica del padron nacional y enlace con clientes
   Flujo: archivos TSE (DIR_PADRON) -> tablas externas EXT_* -> MERGE a
          PADRON_DISTRITO / PADRON_NACIONAL -> enlace con CLIENTE.
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_PADRON AS
    FUNCTION  F_BUSCAR (p_cedula IN VARCHAR2) RETURN PADRON_NACIONAL%ROWTYPE;
    PROCEDURE P_CARGAR_DISTRITOS (p_filas OUT NUMBER);
    PROCEDURE P_CARGAR_PADRON    (p_filas OUT NUMBER);
    PROCEDURE P_ENLAZAR_CLIENTES (p_filas OUT NUMBER);
    PROCEDURE P_CARGAR_TODO;      -- lo invoca el job mensual del scheduler
END PKG_PADRON;
/
CREATE OR REPLACE PACKAGE BODY PKG_PADRON AS

    -- Devuelve la fila del padron para una cedula (PAD_ID NULL si no existe)
    FUNCTION F_BUSCAR (p_cedula IN VARCHAR2) RETURN PADRON_NACIONAL%ROWTYPE IS
        v_fila  PADRON_NACIONAL%ROWTYPE;
        v_vacia PADRON_NACIONAL%ROWTYPE;     -- registro sin asignar: todos sus campos son NULL
    BEGIN
        SELECT * INTO v_fila FROM PADRON_NACIONAL WHERE PAD_CEDULA = TRIM(p_cedula);
        RETURN v_fila;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN v_vacia;
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_PADRON', 'F_BUSCAR', SQLCODE, SQLERRM, p_cedula);
            RAISE;
    END F_BUSCAR;

    PROCEDURE P_CARGAR_DISTRITOS (p_filas OUT NUMBER) IS
    BEGIN
        SAVEPOINT sp_distritos;
        MERGE INTO PADRON_DISTRITO d
        USING (SELECT TRIM(CODELEC) CODELEC, TRIM(PROVINCIA) PROVINCIA,
                      TRIM(CANTON) CANTON, TRIM(DISTRITO) DISTRITO
                 FROM EXT_DISTELEC
                WHERE REGEXP_LIKE(TRIM(CODELEC), '^[0-9]{6}$')) s
           ON (d.PDI_CODELEC = s.CODELEC)
         WHEN MATCHED THEN UPDATE SET d.PDI_PROVINCIA = s.PROVINCIA,
                                      d.PDI_CANTON = s.CANTON, d.PDI_DISTRITO = s.DISTRITO
              WHERE DECODE(d.PDI_PROVINCIA, s.PROVINCIA, 0, 1) +
                    DECODE(d.PDI_CANTON,    s.CANTON,    0, 1) +
                    DECODE(d.PDI_DISTRITO,  s.DISTRITO,  0, 1) > 0
         WHEN NOT MATCHED THEN INSERT (PDI_CODELEC, PDI_PROVINCIA, PDI_CANTON, PDI_DISTRITO)
              VALUES (s.CODELEC, s.PROVINCIA, s.CANTON, s.DISTRITO);
        p_filas := SQL%ROWCOUNT;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_distritos;
            PKG_ERRORES.P_REGISTRAR('PKG_PADRON', 'P_CARGAR_DISTRITOS', SQLCODE, SQLERRM);
            RAISE;
    END P_CARGAR_DISTRITOS;

    -- Carga/actualiza el padron completo con un unico MERGE (solo toca filas nuevas o cambiadas)
    PROCEDURE P_CARGAR_PADRON (p_filas OUT NUMBER) IS
    BEGIN
        SAVEPOINT sp_padron;
        MERGE INTO PADRON_NACIONAL p
        USING (SELECT TRIM(e.CEDULA) CEDULA, TRIM(e.CODELEC) CODELEC,
                      CASE TRIM(e.SEXO) WHEN '1' THEN 'M' ELSE 'F' END SEXO,
                      TO_DATE(TRIM(e.FECHACADUC) DEFAULT NULL ON CONVERSION ERROR, 'YYYYMMDD') FECHA_CADUC,
                      TRIM(e.JUNTA) JUNTA,
                      NVL(TRIM(e.NOMBRE), 'SIN NOMBRE') NOMBRE,
                      NVL(TRIM(e.APELLIDO1), 'SIN APELLIDO') APELLIDO1,
                      TRIM(e.APELLIDO2) APELLIDO2
                 FROM EXT_PADRON e
                WHERE REGEXP_LIKE(TRIM(e.CEDULA), '^[0-9]{9}$')
                  AND EXISTS (SELECT 1 FROM PADRON_DISTRITO d WHERE d.PDI_CODELEC = TRIM(e.CODELEC))) s
           ON (p.PAD_CEDULA = s.CEDULA)
         WHEN MATCHED THEN UPDATE SET p.PAD_CODELEC = s.CODELEC, p.PAD_SEXO = s.SEXO,
                  p.PAD_FECHA_CADUC = s.FECHA_CADUC, p.PAD_JUNTA = s.JUNTA,
                  p.PAD_NOMBRE = s.NOMBRE, p.PAD_APELLIDO1 = s.APELLIDO1, p.PAD_APELLIDO2 = s.APELLIDO2
              WHERE DECODE(p.PAD_CODELEC,     s.CODELEC,     0, 1) +
                    DECODE(p.PAD_SEXO,        s.SEXO,        0, 1) +
                    DECODE(p.PAD_FECHA_CADUC, s.FECHA_CADUC, 0, 1) +
                    DECODE(p.PAD_JUNTA,       s.JUNTA,       0, 1) +
                    DECODE(p.PAD_NOMBRE,      s.NOMBRE,      0, 1) +
                    DECODE(p.PAD_APELLIDO1,   s.APELLIDO1,   0, 1) +
                    DECODE(p.PAD_APELLIDO2,   s.APELLIDO2,   0, 1) > 0
         WHEN NOT MATCHED THEN INSERT (PAD_CEDULA, PAD_CODELEC, PAD_SEXO, PAD_FECHA_CADUC,
                                       PAD_JUNTA, PAD_NOMBRE, PAD_APELLIDO1, PAD_APELLIDO2)
              VALUES (s.CEDULA, s.CODELEC, s.SEXO, s.FECHA_CADUC, s.JUNTA,
                      s.NOMBRE, s.APELLIDO1, s.APELLIDO2);
        p_filas := SQL%ROWCOUNT;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_padron;
            PKG_ERRORES.P_REGISTRAR('PKG_PADRON', 'P_CARGAR_PADRON', SQLCODE, SQLERRM);
            RAISE;
    END P_CARGAR_PADRON;

    -- Enlaza los clientes NACIONALES con el padron y toma de alli sus datos basicos
    PROCEDURE P_ENLAZAR_CLIENTES (p_filas OUT NUMBER) IS
    BEGIN
        SAVEPOINT sp_enlace;
        UPDATE CLIENTE c
           SET (CLI_PAD_ID, CLI_NOMBRE, CLI_APELLIDO1, CLI_APELLIDO2, CLI_SEXO) =
               (SELECT p.PAD_ID, INITCAP(p.PAD_NOMBRE), INITCAP(p.PAD_APELLIDO1),
                       INITCAP(p.PAD_APELLIDO2), p.PAD_SEXO
                  FROM PADRON_NACIONAL p WHERE p.PAD_CEDULA = c.CLI_CEDULA)
         WHERE c.CLI_TIPO_PERSONA = 'NACIONAL'
           AND c.CLI_PAD_ID IS NULL
           AND EXISTS (SELECT 1 FROM PADRON_NACIONAL p WHERE p.PAD_CEDULA = c.CLI_CEDULA);
        p_filas := SQL%ROWCOUNT;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_enlace;
            PKG_ERRORES.P_REGISTRAR('PKG_PADRON', 'P_ENLAZAR_CLIENTES', SQLCODE, SQLERRM);
            RAISE;
    END P_ENLAZAR_CLIENTES;

    -- Proceso completo (programado con DBMS_SCHEDULER una vez al mes)
    PROCEDURE P_CARGAR_TODO IS
        v_dist NUMBER; v_pad NUMBER; v_cli NUMBER;
        v_prl  PROCESO_LOG.PRL_ID%TYPE;
        PROCEDURE P_CERRAR (p_estado VARCHAR2, p_msg VARCHAR2) IS
            PRAGMA AUTONOMOUS_TRANSACTION;
        BEGIN
            UPDATE PROCESO_LOG SET PRL_FIN = SYSDATE, PRL_ESTADO = p_estado,
                   PRL_MENSAJE = SUBSTR(p_msg, 1, 1000) WHERE PRL_ID = v_prl;
            COMMIT;
        END P_CERRAR;
    BEGIN
        INSERT INTO PROCESO_LOG (PRL_PROCESO) VALUES ('PKG_PADRON.P_CARGAR_TODO')
            RETURNING PRL_ID INTO v_prl;
        COMMIT;
        P_CARGAR_DISTRITOS(v_dist);
        P_CARGAR_PADRON(v_pad);
        P_ENLAZAR_CLIENTES(v_cli);
        P_CERRAR('OK', 'Distritos: ' || v_dist || ' | Padron: ' || v_pad || ' | Clientes enlazados: ' || v_cli);
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_PADRON', 'P_CARGAR_TODO', SQLCODE, SQLERRM);
            IF v_prl IS NOT NULL THEN P_CERRAR('ERROR', SQLERRM); END IF;
            RAISE;
    END P_CARGAR_TODO;
END PKG_PADRON;
/
SHOW ERRORS

/* ============================================================================
   PKG_INVENTARIO  -  existencias y bitacora de movimientos
   Todo cambio de stock pasa por P_MOVER_CENTRAL / P_MOVER_SUCURSAL, que
   bloquean la fila (FOR UPDATE WAIT n), validan el saldo y escriben la
   bitacora BIT_MOV_INVENTARIO. Los invocan los triggers (sin COMMIT).
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_INVENTARIO AS
    FUNCTION  F_STOCK_CENTRAL  (p_lot_id IN NUMBER) RETURN NUMBER;
    FUNCTION  F_STOCK_SUCURSAL (p_lot_id IN NUMBER, p_suc_id IN NUMBER) RETURN NUMBER;
    PROCEDURE P_MOVER_CENTRAL  (p_lot_id IN NUMBER, p_delta IN NUMBER,
                                p_tipo IN VARCHAR2, p_referencia IN VARCHAR2);
    PROCEDURE P_MOVER_SUCURSAL (p_lot_id IN NUMBER, p_suc_id IN NUMBER, p_delta IN NUMBER,
                                p_tipo IN VARCHAR2, p_referencia IN VARCHAR2);
    PROCEDURE P_REVERTIR_FACTURA (p_fac_id IN NUMBER, p_suc_id IN NUMBER);
END PKG_INVENTARIO;
/
CREATE OR REPLACE PACKAGE BODY PKG_INVENTARIO AS
    e_ocupado_wait   EXCEPTION;
    e_ocupado_nowait EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_ocupado_wait,   -30006);   -- tiempo de espera agotado (WAIT n)
    PRAGMA EXCEPTION_INIT(e_ocupado_nowait, -54);      -- recurso ocupado (NOWAIT)

    FUNCTION F_STOCK_CENTRAL (p_lot_id IN NUMBER) RETURN NUMBER IS
        v_cant NUMBER;
    BEGIN
        SELECT NVL(SUM(INC_CANTIDAD), 0) INTO v_cant FROM INVENTARIO_CENTRAL WHERE LOT_ID = p_lot_id;
        RETURN v_cant;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_INVENTARIO', 'F_STOCK_CENTRAL', SQLCODE, SQLERRM, 'lote=' || p_lot_id);
            RAISE;
    END F_STOCK_CENTRAL;

    FUNCTION F_STOCK_SUCURSAL (p_lot_id IN NUMBER, p_suc_id IN NUMBER) RETURN NUMBER IS
        v_cant NUMBER;
    BEGIN
        SELECT NVL(SUM(INS_CANTIDAD), 0) INTO v_cant
          FROM INVENTARIO_SUCURSAL WHERE LOT_ID = p_lot_id AND SUC_ID = p_suc_id;
        RETURN v_cant;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_INVENTARIO', 'F_STOCK_SUCURSAL', SQLCODE, SQLERRM,
                                    'lote=' || p_lot_id || ' suc=' || p_suc_id);
            RAISE;
    END F_STOCK_SUCURSAL;

    -- Movimiento en la bodega central (delta > 0 entra, delta < 0 sale)
    PROCEDURE P_MOVER_CENTRAL (p_lot_id IN NUMBER, p_delta IN NUMBER,
                               p_tipo IN VARCHAR2, p_referencia IN VARCHAR2) IS
        v_ant NUMBER;
        v_nue NUMBER;
    BEGIN
        BEGIN
            -- Bloqueo de la fila con espera parametrizada (WAIT n)
            EXECUTE IMMEDIATE
                'SELECT INC_CANTIDAD FROM INVENTARIO_CENTRAL WHERE LOT_ID = :1 FOR UPDATE WAIT '
                || PKG_UTIL.F_ESPERA_BLOQUEO
                INTO v_ant USING p_lot_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_ant := NULL;                        -- el lote aun no tiene fila en bodega central
        END;

        IF v_ant IS NULL THEN
            IF p_delta < 0 THEN
                RAISE_APPLICATION_ERROR(-20121, 'Stock insuficiente: el lote ' || p_lot_id ||
                                        ' no existe en la bodega central.');
            END IF;
            INSERT INTO INVENTARIO_CENTRAL (LOT_ID, INC_CANTIDAD) VALUES (p_lot_id, p_delta);
            v_ant := 0;
            v_nue := p_delta;
        ELSE
            v_nue := v_ant + p_delta;
            IF v_nue < 0 THEN
                RAISE_APPLICATION_ERROR(-20121, 'Stock insuficiente en bodega central: lote ' || p_lot_id ||
                                        ', disponible ' || v_ant || ', solicitado ' || ABS(p_delta) || '.');
            END IF;
            UPDATE INVENTARIO_CENTRAL SET INC_CANTIDAD = v_nue WHERE LOT_ID = p_lot_id;
        END IF;

        INSERT INTO BIT_MOV_INVENTARIO (BMI_UBICACION, SUC_ID, LOT_ID, BMI_TIPO, BMI_CANTIDAD,
                                        BMI_SALDO_ANT, BMI_SALDO_NUE, BMI_REFERENCIA, BMI_USUARIO)
        VALUES ('CENTRAL', NULL, p_lot_id, p_tipo, p_delta, v_ant, v_nue, p_referencia, PKG_UTIL.F_USUARIO_BD);
    EXCEPTION
        WHEN e_ocupado_wait OR e_ocupado_nowait THEN
            PKG_ERRORES.P_REGISTRAR('PKG_INVENTARIO', 'P_MOVER_CENTRAL', SQLCODE, SQLERRM, 'lote=' || p_lot_id);
            RAISE_APPLICATION_ERROR(-20190, 'El inventario del lote ' || p_lot_id ||
                                    ' esta siendo modificado por otra sesion. Reintente.');
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_INVENTARIO', 'P_MOVER_CENTRAL', SQLCODE, SQLERRM,
                                    'lote=' || p_lot_id || ' delta=' || p_delta || ' tipo=' || p_tipo);
            RAISE;
    END P_MOVER_CENTRAL;

    -- Movimiento en el inventario de una sucursal
    PROCEDURE P_MOVER_SUCURSAL (p_lot_id IN NUMBER, p_suc_id IN NUMBER, p_delta IN NUMBER,
                                p_tipo IN VARCHAR2, p_referencia IN VARCHAR2) IS
        v_ant NUMBER;
        v_nue NUMBER;
    BEGIN
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT INS_CANTIDAD FROM INVENTARIO_SUCURSAL WHERE LOT_ID = :1 AND SUC_ID = :2 FOR UPDATE WAIT '
                || PKG_UTIL.F_ESPERA_BLOQUEO
                INTO v_ant USING p_lot_id, p_suc_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_ant := NULL;
        END;

        IF v_ant IS NULL THEN
            IF p_delta < 0 THEN
                RAISE_APPLICATION_ERROR(-20121, 'Stock insuficiente: el lote ' || p_lot_id ||
                                        ' no existe en la sucursal ' || p_suc_id || '.');
            END IF;
            INSERT INTO INVENTARIO_SUCURSAL (LOT_ID, SUC_ID, INS_CANTIDAD) VALUES (p_lot_id, p_suc_id, p_delta);
            v_ant := 0;
            v_nue := p_delta;
        ELSE
            v_nue := v_ant + p_delta;
            IF v_nue < 0 THEN
                RAISE_APPLICATION_ERROR(-20121, 'Stock insuficiente en la sucursal ' || p_suc_id || ': lote ' ||
                                        p_lot_id || ', disponible ' || v_ant || ', solicitado ' || ABS(p_delta) || '.');
            END IF;
            UPDATE INVENTARIO_SUCURSAL SET INS_CANTIDAD = v_nue WHERE LOT_ID = p_lot_id AND SUC_ID = p_suc_id;
        END IF;

        INSERT INTO BIT_MOV_INVENTARIO (BMI_UBICACION, SUC_ID, LOT_ID, BMI_TIPO, BMI_CANTIDAD,
                                        BMI_SALDO_ANT, BMI_SALDO_NUE, BMI_REFERENCIA, BMI_USUARIO)
        VALUES ('SUCURSAL', p_suc_id, p_lot_id, p_tipo, p_delta, v_ant, v_nue, p_referencia, PKG_UTIL.F_USUARIO_BD);
    EXCEPTION
        WHEN e_ocupado_wait OR e_ocupado_nowait THEN
            PKG_ERRORES.P_REGISTRAR('PKG_INVENTARIO', 'P_MOVER_SUCURSAL', SQLCODE, SQLERRM,
                                    'lote=' || p_lot_id || ' suc=' || p_suc_id);
            RAISE_APPLICATION_ERROR(-20190, 'El inventario del lote ' || p_lot_id ||
                                    ' en la sucursal ' || p_suc_id || ' esta siendo modificado por otra sesion. Reintente.');
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_INVENTARIO', 'P_MOVER_SUCURSAL', SQLCODE, SQLERRM,
                                    'lote=' || p_lot_id || ' suc=' || p_suc_id || ' delta=' || p_delta);
            RAISE;
    END P_MOVER_SUCURSAL;

    -- Devuelve al inventario de la sucursal todo lo facturado (factura anulada)
    PROCEDURE P_REVERTIR_FACTURA (p_fac_id IN NUMBER, p_suc_id IN NUMBER) IS
    BEGIN
        FOR r IN (SELECT LOT_ID, FCD_CANTIDAD FROM FAC_DETALLE
                   WHERE FAC_ID = p_fac_id AND LOT_ID IS NOT NULL) LOOP
            P_MOVER_SUCURSAL(r.LOT_ID, p_suc_id, r.FCD_CANTIDAD, 'ANULACION', 'FAC-' || p_fac_id);
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_INVENTARIO', 'P_REVERTIR_FACTURA', SQLCODE, SQLERRM, 'fac=' || p_fac_id);
            RAISE;
    END P_REVERTIR_FACTURA;
END PKG_INVENTARIO;
/

/* ============================================================================
   PKG_PRECIOS  -  historial automatico de precios
   Cuando cambia el costo de un producto (o la utilidad de un producto en un
   negocio) se cierra el registro vigente de HISTORICO_PRECIO y se abre uno
   nuevo; ademas se anota el antes/despues en BIT_CAMBIO_PRECIO.
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_PRECIOS AS
    g_motivo VARCHAR2(200);      -- motivo que usa el trigger (lo fija quien cambia el costo)
    FUNCTION  F_PRECIO_VENTA (p_costo IN NUMBER, p_utilidad IN NUMBER, p_tasa IN NUMBER) RETURN NUMBER;
    PROCEDURE P_REGISTRAR_CAMBIO_COSTO (p_prd_id IN NUMBER, p_costo_nue IN NUMBER, p_imp_id IN NUMBER);
    PROCEDURE P_REGISTRAR_CAMBIO_UTILIDAD (p_prd_id IN NUMBER, p_neg_id IN NUMBER, p_utilidad_nue IN NUMBER);
    PROCEDURE P_CAMBIAR_COSTO (p_prd_id IN NUMBER, p_nuevo_costo IN NUMBER, p_motivo IN VARCHAR2 DEFAULT NULL);
END PKG_PRECIOS;
/
CREATE OR REPLACE PACKAGE BODY PKG_PRECIOS AS

    -- Precio de venta sin descuentos: costo x (1 + utilidad%) x (1 + impuesto%)
    FUNCTION F_PRECIO_VENTA (p_costo IN NUMBER, p_utilidad IN NUMBER, p_tasa IN NUMBER) RETURN NUMBER IS
    BEGIN
        RETURN ROUND(p_costo * (1 + NVL(p_utilidad, 0) / 100) * (1 + NVL(p_tasa, 0) / 100), 2);
    END F_PRECIO_VENTA;

    -- Cierra el precio vigente y abre el nuevo (uno por producto y negocio)
    PROCEDURE P_ROTAR (p_prd_id IN NUMBER, p_neg_id IN NUMBER, p_costo IN NUMBER,
                       p_utilidad IN NUMBER, p_tasa IN NUMBER) IS
        v_his_id   HISTORICO_PRECIO.HIS_ID%TYPE;
        v_desde_a  DATE;
        v_costo_a  NUMBER;
        v_precio_a NUMBER;
        v_desde    DATE;
        v_precio   NUMBER;
    BEGIN
        BEGIN
            SELECT HIS_ID, HIS_FECHA_DESDE, HIS_COSTO, HIS_PRECIO_VENTA
              INTO v_his_id, v_desde_a, v_costo_a, v_precio_a
              FROM HISTORICO_PRECIO
             WHERE PRD_ID = p_prd_id AND NEG_ID = p_neg_id AND HIS_FECHA_HASTA IS NULL
               FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_his_id := NULL;
        END;

        -- la nueva vigencia nunca coincide con la anterior (llave unica PRD, NEG, DESDE)
        v_desde  := GREATEST(SYSDATE, NVL(v_desde_a, SYSDATE - 1) + 1 / 86400);
        v_precio := F_PRECIO_VENTA(p_costo, p_utilidad, p_tasa);

        IF v_his_id IS NOT NULL THEN
            UPDATE HISTORICO_PRECIO SET HIS_FECHA_HASTA = v_desde WHERE HIS_ID = v_his_id;
        END IF;

        INSERT INTO HISTORICO_PRECIO (PRD_ID, NEG_ID, HIS_COSTO, HIS_PORC_UTILIDAD, HIS_TASA_IMPUESTO,
                                      HIS_PRECIO_VENTA, HIS_FECHA_DESDE, HIS_FECHA_HASTA, USR_ID, HIS_MOTIVO)
        VALUES (p_prd_id, p_neg_id, p_costo, p_utilidad, NVL(p_tasa, 0), v_precio, v_desde, NULL,
                PKG_UTIL.F_USUARIO_APP, SUBSTR(NVL(g_motivo, 'Cambio automatico de costo o utilidad'), 1, 200));

        INSERT INTO BIT_CAMBIO_PRECIO (PRD_ID, NEG_ID, BCP_COSTO_ANT, BCP_COSTO_NUE, BCP_PRECIO_ANT,
                                       BCP_PRECIO_NUE, BCP_USUARIO, BCP_MOTIVO)
        VALUES (p_prd_id, p_neg_id, v_costo_a, p_costo, v_precio_a, v_precio, PKG_UTIL.F_USUARIO_BD,
                SUBSTR(NVL(g_motivo, 'Cambio automatico de costo o utilidad'), 1, 200));
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_PRECIOS', 'P_ROTAR', SQLCODE, SQLERRM,
                                    'prd=' || p_prd_id || ' neg=' || p_neg_id);
            RAISE;
    END P_ROTAR;

    -- Lo invoca el trigger de PRODUCTO cuando cambia PRD_PRECIO_COSTO
    PROCEDURE P_REGISTRAR_CAMBIO_COSTO (p_prd_id IN NUMBER, p_costo_nue IN NUMBER, p_imp_id IN NUMBER) IS
        v_tasa NUMBER := 0;
    BEGIN
        IF p_imp_id IS NOT NULL THEN
            SELECT NVL(IMP_TASA, 0) INTO v_tasa FROM IMPUESTO WHERE IMP_ID = p_imp_id;
        END IF;
        FOR r IN (SELECT NEG_ID, PRN_PORC_UTILIDAD FROM PRODUCTO_NEGOCIO WHERE PRD_ID = p_prd_id) LOOP
            P_ROTAR(p_prd_id, r.NEG_ID, p_costo_nue, r.PRN_PORC_UTILIDAD, v_tasa);
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_PRECIOS', 'P_REGISTRAR_CAMBIO_COSTO', SQLCODE, SQLERRM, 'prd=' || p_prd_id);
            RAISE;
    END P_REGISTRAR_CAMBIO_COSTO;

    -- Lo invoca el trigger de PRODUCTO_NEGOCIO cuando cambia la utilidad
    PROCEDURE P_REGISTRAR_CAMBIO_UTILIDAD (p_prd_id IN NUMBER, p_neg_id IN NUMBER, p_utilidad_nue IN NUMBER) IS
        v_costo NUMBER;
        v_tasa  NUMBER := 0;
    BEGIN
        SELECT p.PRD_PRECIO_COSTO, NVL(i.IMP_TASA, 0) INTO v_costo, v_tasa
          FROM PRODUCTO p LEFT JOIN IMPUESTO i ON i.IMP_ID = p.IMP_ID
         WHERE p.PRD_ID = p_prd_id;
        P_ROTAR(p_prd_id, p_neg_id, v_costo, p_utilidad_nue, v_tasa);
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_PRECIOS', 'P_REGISTRAR_CAMBIO_UTILIDAD', SQLCODE, SQLERRM,
                                    'prd=' || p_prd_id || ' neg=' || p_neg_id);
            RAISE;
    END P_REGISTRAR_CAMBIO_UTILIDAD;

    -- API publica: cambia el costo de un producto (el trigger registra el historial)
    PROCEDURE P_CAMBIAR_COSTO (p_prd_id IN NUMBER, p_nuevo_costo IN NUMBER, p_motivo IN VARCHAR2 DEFAULT NULL) IS
        v_actual PRODUCTO.PRD_PRECIO_COSTO%TYPE;
    BEGIN
        SAVEPOINT sp_cambiar_costo;
        IF p_nuevo_costo IS NULL OR p_nuevo_costo < 0 THEN
            RAISE_APPLICATION_ERROR(-20150, 'El nuevo costo debe ser mayor o igual a cero.');
        END IF;
        EXECUTE IMMEDIATE 'SELECT PRD_PRECIO_COSTO FROM PRODUCTO WHERE PRD_ID = :1 FOR UPDATE WAIT '
                          || PKG_UTIL.F_ESPERA_BLOQUEO INTO v_actual USING p_prd_id;
        IF v_actual <> p_nuevo_costo THEN
            g_motivo := p_motivo;
            UPDATE PRODUCTO SET PRD_PRECIO_COSTO = p_nuevo_costo WHERE PRD_ID = p_prd_id;
            g_motivo := NULL;
        END IF;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            g_motivo := NULL;
            ROLLBACK TO sp_cambiar_costo;
            PKG_ERRORES.P_REGISTRAR('PKG_PRECIOS', 'P_CAMBIAR_COSTO', SQLCODE, SQLERRM,
                                    'prd=' || p_prd_id || ' costo=' || p_nuevo_costo);
            RAISE;
    END P_CAMBIAR_COSTO;
END PKG_PRECIOS;
/
SHOW ERRORS

/* ============================================================================
   PKG_CUENTAS  -  cuentas por cobrar (clientes) y por pagar (proveedores)
   * Validacion de limites de credito (cliente y proveedor)
   * Aumento automatico de saldos al registrar facturas pendientes
   * Aplicacion de abonos, notas de credito y devoluciones a proveedor
   * Cambio automatico de estado PENDIENTE -> CANCELADA
   Los procedimientos P_VALIDAR_*, P_REGISTRAR_CXC, P_AUMENTAR_*, P_APLICAR_*
   y P_ANULAR_CXC los invocan los triggers (sin COMMIT). Los P_REGISTRAR_ABONO_*
   son la API publica (con SAVEPOINT y COMMIT).
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_CUENTAS AS
    PROCEDURE P_VALIDAR_LIMITE_CLIENTE   (p_cli_id IN NUMBER, p_monto IN NUMBER);
    PROCEDURE P_VALIDAR_LIMITE_PROVEEDOR (p_prv_id IN NUMBER, p_monto IN NUMBER);
    PROCEDURE P_REGISTRAR_CXC            (p_fac_id IN NUMBER, p_cli_id IN NUMBER,
                                          p_fecha IN DATE, p_total IN NUMBER);
    PROCEDURE P_AUMENTAR_SALDO_PROVEEDOR (p_prv_id IN NUMBER, p_monto IN NUMBER);
    PROCEDURE P_APLICAR_ABONO_CXC        (p_cxc_id IN NUMBER, p_monto IN NUMBER);
    PROCEDURE P_APLICAR_ABONO_CXP        (p_cxp_id IN NUMBER, p_monto IN NUMBER);
    PROCEDURE P_APLICAR_NOTA_CREDITO     (p_fac_id IN NUMBER, p_monto IN NUMBER, p_tipo IN VARCHAR2);
    PROCEDURE P_APLICAR_DEVOLUCION_PRV   (p_cxp_id IN NUMBER, p_monto IN NUMBER);
    PROCEDURE P_ANULAR_CXC               (p_fac_id IN NUMBER);
    -- API publica
    PROCEDURE P_REGISTRAR_ABONO_CXC (p_cxc_id IN NUMBER, p_fpg_id IN NUMBER, p_monto IN NUMBER,
                                     p_referencia IN VARCHAR2 DEFAULT NULL);
    PROCEDURE P_REGISTRAR_ABONO_CXP (p_cxp_id IN NUMBER, p_fpg_id IN NUMBER, p_monto IN NUMBER,
                                     p_referencia IN VARCHAR2 DEFAULT NULL);
END PKG_CUENTAS;
/
CREATE OR REPLACE PACKAGE BODY PKG_CUENTAS AS
    e_ocupado_wait EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_ocupado_wait, -30006);

    /* ------------------------------------------------------------------
       Limite de credito del CLIENTE: saldo actual + factura <= limite.
       Bloquea la fila del cliente (FOR UPDATE WAIT n) para que dos facturas
       simultaneas no superen el limite entre las dos.
       ------------------------------------------------------------------ */
    PROCEDURE P_VALIDAR_LIMITE_CLIENTE (p_cli_id IN NUMBER, p_monto IN NUMBER) IS
        v_saldo  CLIENTE.CLI_SALDO_ACTUAL%TYPE;
        v_limite CLIENTE.CLI_LIMITE_CREDITO%TYPE;
        v_pref   CLIENTE.CLI_PREFERENCIAL%TYPE;
        v_estado CLIENTE.CLI_ESTADO%TYPE;
    BEGIN
        EXECUTE IMMEDIATE
            'SELECT CLI_SALDO_ACTUAL, CLI_LIMITE_CREDITO, CLI_PREFERENCIAL, CLI_ESTADO ' ||
            'FROM CLIENTE WHERE CLI_ID = :1 FOR UPDATE WAIT ' || PKG_UTIL.F_ESPERA_BLOQUEO
            INTO v_saldo, v_limite, v_pref, v_estado USING p_cli_id;

        IF v_estado <> 'A' THEN
            RAISE_APPLICATION_ERROR(-20103, 'El cliente ' || p_cli_id || ' esta inactivo.');
        END IF;
        IF v_pref <> 'S' THEN
            RAISE_APPLICATION_ERROR(-20101, 'El cliente ' || p_cli_id ||
                ' no es preferencial: no puede dejar facturas pendientes de pago.');
        END IF;
        IF v_saldo + p_monto > v_limite THEN
            RAISE_APPLICATION_ERROR(-20102, 'Limite de credito excedido: saldo actual ' ||
                PKG_UTIL.F_MONTO(v_saldo) || ' + factura ' || PKG_UTIL.F_MONTO(p_monto) ||
                ' supera el limite de ' || PKG_UTIL.F_MONTO(v_limite) || '.');
        END IF;
    EXCEPTION
        WHEN e_ocupado_wait THEN
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_VALIDAR_LIMITE_CLIENTE', SQLCODE, SQLERRM, 'cli=' || p_cli_id);
            RAISE_APPLICATION_ERROR(-20190, 'El cliente ' || p_cli_id || ' esta siendo modificado por otra sesion. Reintente.');
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_VALIDAR_LIMITE_CLIENTE', SQLCODE, SQLERRM,
                                    'cli=' || p_cli_id || ' monto=' || p_monto);
            RAISE;
    END P_VALIDAR_LIMITE_CLIENTE;

    -- Limite de credito con el PROVEEDOR: saldo actual + factura <= limite
    PROCEDURE P_VALIDAR_LIMITE_PROVEEDOR (p_prv_id IN NUMBER, p_monto IN NUMBER) IS
        v_saldo  PROVEEDOR.PRV_SALDO_ACTUAL%TYPE;
        v_limite PROVEEDOR.PRV_LIMITE_CREDITO%TYPE;
        v_estado PROVEEDOR.PRV_ESTADO%TYPE;
    BEGIN
        EXECUTE IMMEDIATE
            'SELECT PRV_SALDO_ACTUAL, PRV_LIMITE_CREDITO, PRV_ESTADO ' ||
            'FROM PROVEEDOR WHERE PRV_ID = :1 FOR UPDATE WAIT ' || PKG_UTIL.F_ESPERA_BLOQUEO
            INTO v_saldo, v_limite, v_estado USING p_prv_id;

        IF v_estado <> 'A' THEN
            RAISE_APPLICATION_ERROR(-20112, 'El proveedor ' || p_prv_id || ' esta inactivo.');
        END IF;
        IF v_saldo + p_monto > v_limite THEN
            RAISE_APPLICATION_ERROR(-20111, 'Limite de credito con el proveedor excedido: saldo actual ' ||
                PKG_UTIL.F_MONTO(v_saldo) || ' + factura ' || PKG_UTIL.F_MONTO(p_monto) ||
                ' supera el limite de ' || PKG_UTIL.F_MONTO(v_limite) || '.');
        END IF;
    EXCEPTION
        WHEN e_ocupado_wait THEN
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_VALIDAR_LIMITE_PROVEEDOR', SQLCODE, SQLERRM, 'prv=' || p_prv_id);
            RAISE_APPLICATION_ERROR(-20190, 'El proveedor ' || p_prv_id || ' esta siendo modificado por otra sesion. Reintente.');
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_VALIDAR_LIMITE_PROVEEDOR', SQLCODE, SQLERRM,
                                    'prv=' || p_prv_id || ' monto=' || p_monto);
            RAISE;
    END P_VALIDAR_LIMITE_PROVEEDOR;

    -- Factura a cliente PENDIENTE: crea la cuenta por cobrar y aumenta el saldo del cliente
    PROCEDURE P_REGISTRAR_CXC (p_fac_id IN NUMBER, p_cli_id IN NUMBER,
                               p_fecha IN DATE, p_total IN NUMBER) IS
        v_plazo NUMBER;
    BEGIN
        v_plazo := PKG_PARAMETROS.F_NUMERO('CXC_DIAS_PLAZO', 30);
        INSERT INTO CUENTA_POR_COBRAR (CLI_ID, FAC_ID, CXC_FECHA_VENCIMIENTO, CXC_MONTO, CXC_SALDO, CXC_ESTADO)
        VALUES (p_cli_id, p_fac_id, TRUNC(p_fecha) + v_plazo, p_total, p_total, 'PENDIENTE');
        UPDATE CLIENTE SET CLI_SALDO_ACTUAL = CLI_SALDO_ACTUAL + p_total WHERE CLI_ID = p_cli_id;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_REGISTRAR_CXC', SQLCODE, SQLERRM,
                                    'fac=' || p_fac_id || ' cli=' || p_cli_id);
            RAISE;
    END P_REGISTRAR_CXC;

    -- Factura de proveedor PENDIENTE: aumenta lo que se le debe
    PROCEDURE P_AUMENTAR_SALDO_PROVEEDOR (p_prv_id IN NUMBER, p_monto IN NUMBER) IS
    BEGIN
        UPDATE PROVEEDOR SET PRV_SALDO_ACTUAL = PRV_SALDO_ACTUAL + p_monto WHERE PRV_ID = p_prv_id;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_AUMENTAR_SALDO_PROVEEDOR', SQLCODE, SQLERRM,
                                    'prv=' || p_prv_id || ' monto=' || p_monto);
            RAISE;
    END P_AUMENTAR_SALDO_PROVEEDOR;

    -- Abono del cliente: baja el saldo; si queda en cero la cuenta se PAGA y la factura pasa a CANCELADA
    PROCEDURE P_APLICAR_ABONO_CXC (p_cxc_id IN NUMBER, p_monto IN NUMBER) IS
        v_saldo  CUENTA_POR_COBRAR.CXC_SALDO%TYPE;
        v_estado CUENTA_POR_COBRAR.CXC_ESTADO%TYPE;
        v_cli    CUENTA_POR_COBRAR.CLI_ID%TYPE;
        v_fac    CUENTA_POR_COBRAR.FAC_ID%TYPE;
        v_nuevo  NUMBER;
    BEGIN
        SELECT CXC_SALDO, CXC_ESTADO, CLI_ID, FAC_ID INTO v_saldo, v_estado, v_cli, v_fac
          FROM CUENTA_POR_COBRAR WHERE CXC_ID = p_cxc_id FOR UPDATE;      -- bloqueo simple

        IF v_estado NOT IN ('PENDIENTE', 'PARCIAL') THEN
            RAISE_APPLICATION_ERROR(-20141, 'La cuenta por cobrar ' || p_cxc_id || ' esta ' || v_estado ||
                                    ' y no admite abonos.');
        END IF;
        IF p_monto > v_saldo THEN
            RAISE_APPLICATION_ERROR(-20142, 'El abono ' || PKG_UTIL.F_MONTO(p_monto) ||
                                    ' supera el saldo pendiente ' || PKG_UTIL.F_MONTO(v_saldo) || '.');
        END IF;

        v_nuevo := v_saldo - p_monto;
        UPDATE CUENTA_POR_COBRAR
           SET CXC_SALDO = v_nuevo,
               CXC_ESTADO = CASE WHEN v_nuevo = 0 THEN 'PAGADA' ELSE 'PARCIAL' END
         WHERE CXC_ID = p_cxc_id;
        UPDATE CLIENTE SET CLI_SALDO_ACTUAL = CLI_SALDO_ACTUAL - p_monto WHERE CLI_ID = v_cli;

        IF v_nuevo = 0 THEN                       -- cancelada totalmente: PENDIENTE -> CANCELADA
            UPDATE FACTURA SET FAC_ESTADO = 'CANCELADA'
             WHERE FAC_ID = v_fac AND FAC_ESTADO = 'PENDIENTE';
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_APLICAR_ABONO_CXC', SQLCODE, SQLERRM,
                                    'cxc=' || p_cxc_id || ' monto=' || p_monto);
            RAISE;
    END P_APLICAR_ABONO_CXC;

    -- Abono al proveedor: baja el saldo; si queda en cero la cuenta pasa a PAGADA
    PROCEDURE P_APLICAR_ABONO_CXP (p_cxp_id IN NUMBER, p_monto IN NUMBER) IS
        v_saldo  CUENTA_POR_PAGAR.CXP_SALDO%TYPE;
        v_estado CUENTA_POR_PAGAR.CXP_ESTADO%TYPE;
        v_prv    CUENTA_POR_PAGAR.PRV_ID%TYPE;
        v_nuevo  NUMBER;
    BEGIN
        SELECT CXP_SALDO, CXP_ESTADO, PRV_ID INTO v_saldo, v_estado, v_prv
          FROM CUENTA_POR_PAGAR WHERE CXP_ID = p_cxp_id FOR UPDATE;

        IF v_estado NOT IN ('PENDIENTE', 'PARCIAL') THEN
            RAISE_APPLICATION_ERROR(-20141, 'La cuenta por pagar ' || p_cxp_id || ' esta ' || v_estado ||
                                    ' y no admite abonos.');
        END IF;
        IF p_monto > v_saldo THEN
            RAISE_APPLICATION_ERROR(-20142, 'El abono ' || PKG_UTIL.F_MONTO(p_monto) ||
                                    ' supera el saldo pendiente ' || PKG_UTIL.F_MONTO(v_saldo) || '.');
        END IF;

        v_nuevo := v_saldo - p_monto;
        UPDATE CUENTA_POR_PAGAR
           SET CXP_SALDO = v_nuevo,
               CXP_ESTADO = CASE WHEN v_nuevo = 0 THEN 'PAGADA' ELSE 'PARCIAL' END
         WHERE CXP_ID = p_cxp_id;
        UPDATE PROVEEDOR SET PRV_SALDO_ACTUAL = PRV_SALDO_ACTUAL - p_monto WHERE PRV_ID = v_prv;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_APLICAR_ABONO_CXP', SQLCODE, SQLERRM,
                                    'cxp=' || p_cxp_id || ' monto=' || p_monto);
            RAISE;
    END P_APLICAR_ABONO_CXP;

    /* Nota de credito de un cliente: si la factura estaba pendiente se rebaja el saldo
       (hasta donde alcance); una nota TOTAL deja la factura DEVUELTA y la cuenta ANULADA. */
    PROCEDURE P_APLICAR_NOTA_CREDITO (p_fac_id IN NUMBER, p_monto IN NUMBER, p_tipo IN VARCHAR2) IS
        v_cxc    CUENTA_POR_COBRAR.CXC_ID%TYPE;
        v_saldo  CUENTA_POR_COBRAR.CXC_SALDO%TYPE;
        v_cli    CUENTA_POR_COBRAR.CLI_ID%TYPE;
        v_aplica NUMBER;
        v_nuevo  NUMBER;
    BEGIN
        BEGIN
            SELECT CXC_ID, CXC_SALDO, CLI_ID INTO v_cxc, v_saldo, v_cli
              FROM CUENTA_POR_COBRAR
             WHERE FAC_ID = p_fac_id AND CXC_ESTADO IN ('PENDIENTE', 'PARCIAL') FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_cxc := NULL;                    -- factura de contado o cuenta ya cerrada
        END;

        IF v_cxc IS NOT NULL THEN
            v_aplica := LEAST(p_monto, v_saldo);
            v_nuevo  := v_saldo - v_aplica;
            UPDATE CUENTA_POR_COBRAR
               SET CXC_SALDO = v_nuevo,
                   CXC_ESTADO = CASE WHEN v_nuevo > 0 THEN 'PARCIAL'
                                     WHEN p_tipo = 'TOTAL' THEN 'ANULADA'
                                     ELSE 'PAGADA' END
             WHERE CXC_ID = v_cxc;
            UPDATE CLIENTE SET CLI_SALDO_ACTUAL = CLI_SALDO_ACTUAL - v_aplica WHERE CLI_ID = v_cli;
            IF v_nuevo = 0 AND p_tipo <> 'TOTAL' THEN
                UPDATE FACTURA SET FAC_ESTADO = 'CANCELADA'
                 WHERE FAC_ID = p_fac_id AND FAC_ESTADO = 'PENDIENTE';
            END IF;
        END IF;

        IF p_tipo = 'TOTAL' THEN
            UPDATE FACTURA SET FAC_ESTADO = 'DEVUELTA'
             WHERE FAC_ID = p_fac_id AND FAC_ESTADO IN ('PENDIENTE', 'CANCELADA');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_APLICAR_NOTA_CREDITO', SQLCODE, SQLERRM,
                                    'fac=' || p_fac_id || ' monto=' || p_monto);
            RAISE;
    END P_APLICAR_NOTA_CREDITO;

    -- Devolucion a proveedor aplicada contra una cuenta por pagar
    PROCEDURE P_APLICAR_DEVOLUCION_PRV (p_cxp_id IN NUMBER, p_monto IN NUMBER) IS
        v_saldo  CUENTA_POR_PAGAR.CXP_SALDO%TYPE;
        v_estado CUENTA_POR_PAGAR.CXP_ESTADO%TYPE;
        v_prv    CUENTA_POR_PAGAR.PRV_ID%TYPE;
        v_aplica NUMBER;
        v_nuevo  NUMBER;
    BEGIN
        SELECT CXP_SALDO, CXP_ESTADO, PRV_ID INTO v_saldo, v_estado, v_prv
          FROM CUENTA_POR_PAGAR WHERE CXP_ID = p_cxp_id FOR UPDATE;
        IF v_estado IN ('PENDIENTE', 'PARCIAL') THEN
            v_aplica := LEAST(p_monto, v_saldo);
            v_nuevo  := v_saldo - v_aplica;
            UPDATE CUENTA_POR_PAGAR
               SET CXP_SALDO = v_nuevo,
                   CXP_ESTADO = CASE WHEN v_nuevo = 0 THEN 'PAGADA' ELSE 'PARCIAL' END
             WHERE CXP_ID = p_cxp_id;
            UPDATE PROVEEDOR SET PRV_SALDO_ACTUAL = PRV_SALDO_ACTUAL - v_aplica WHERE PRV_ID = v_prv;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_APLICAR_DEVOLUCION_PRV', SQLCODE, SQLERRM,
                                    'cxp=' || p_cxp_id || ' monto=' || p_monto);
            RAISE;
    END P_APLICAR_DEVOLUCION_PRV;

    -- Factura anulada: la cuenta por cobrar se anula y el cliente deja de deber ese saldo
    PROCEDURE P_ANULAR_CXC (p_fac_id IN NUMBER) IS
        v_cxc   CUENTA_POR_COBRAR.CXC_ID%TYPE;
        v_saldo CUENTA_POR_COBRAR.CXC_SALDO%TYPE;
        v_cli   CUENTA_POR_COBRAR.CLI_ID%TYPE;
    BEGIN
        BEGIN
            SELECT CXC_ID, CXC_SALDO, CLI_ID INTO v_cxc, v_saldo, v_cli
              FROM CUENTA_POR_COBRAR
             WHERE FAC_ID = p_fac_id AND CXC_ESTADO IN ('PENDIENTE', 'PARCIAL') FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RETURN;                           -- nada que anular (factura de contado)
        END;
        UPDATE CUENTA_POR_COBRAR SET CXC_SALDO = 0, CXC_ESTADO = 'ANULADA' WHERE CXC_ID = v_cxc;
        UPDATE CLIENTE SET CLI_SALDO_ACTUAL = CLI_SALDO_ACTUAL - v_saldo WHERE CLI_ID = v_cli;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_ANULAR_CXC', SQLCODE, SQLERRM, 'fac=' || p_fac_id);
            RAISE;
    END P_ANULAR_CXC;

    -- API publica: registra un abono de cliente (el trigger TRG_ABC_AIR aplica el saldo)
    PROCEDURE P_REGISTRAR_ABONO_CXC (p_cxc_id IN NUMBER, p_fpg_id IN NUMBER, p_monto IN NUMBER,
                                     p_referencia IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        SAVEPOINT sp_abono_cxc;
        INSERT INTO CXC_ABONO (CXC_ID, FPG_ID, ABC_FECHA, ABC_MONTO, ABC_REFERENCIA)
        VALUES (p_cxc_id, p_fpg_id, SYSDATE, p_monto, p_referencia);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_abono_cxc;
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_REGISTRAR_ABONO_CXC', SQLCODE, SQLERRM,
                                    'cxc=' || p_cxc_id || ' monto=' || p_monto);
            RAISE;
    END P_REGISTRAR_ABONO_CXC;

    -- API publica: registra un abono a proveedor (el trigger TRG_ABO_AIR aplica el saldo)
    PROCEDURE P_REGISTRAR_ABONO_CXP (p_cxp_id IN NUMBER, p_fpg_id IN NUMBER, p_monto IN NUMBER,
                                     p_referencia IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        SAVEPOINT sp_abono_cxp;
        INSERT INTO CXP_ABONO (CXP_ID, FPG_ID, ABO_FECHA, ABO_MONTO, ABO_REFERENCIA)
        VALUES (p_cxp_id, p_fpg_id, SYSDATE, p_monto, p_referencia);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_abono_cxp;
            PKG_ERRORES.P_REGISTRAR('PKG_CUENTAS', 'P_REGISTRAR_ABONO_CXP', SQLCODE, SQLERRM,
                                    'cxp=' || p_cxp_id || ' monto=' || p_monto);
            RAISE;
    END P_REGISTRAR_ABONO_CXP;
END PKG_CUENTAS;
/

/* ============================================================================
   PKG_COMPRAS  -  facturas de proveedor y devoluciones a proveedor
   Una factura de proveedor pendiente de pago es una fila de CUENTA_POR_PAGAR.
   Al insertar sus lineas (CXP_DETALLE) el trigger llama a P_RECIBIR_LINEA, que
   aumenta el inventario central y registra el cambio de costo si cambio.
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_COMPRAS AS
    TYPE t_linea_compra IS RECORD (
        prd_id      NUMBER,
        lote_numero VARCHAR2(30),     -- NULL = se genera automaticamente
        cantidad    NUMBER,
        costo       NUMBER,
        fecha_venc  DATE);
    TYPE t_lineas_compra IS TABLE OF t_linea_compra INDEX BY PLS_INTEGER;

    TYPE t_linea_dev_prv IS RECORD (lot_id NUMBER, cantidad NUMBER);
    TYPE t_lineas_dev_prv IS TABLE OF t_linea_dev_prv INDEX BY PLS_INTEGER;

    PROCEDURE P_RECIBIR_LINEA (p_cxp_id IN NUMBER, p_lot_id IN NUMBER,
                               p_cantidad IN NUMBER, p_precio IN NUMBER);
    PROCEDURE P_REGISTRAR_COMPRA (p_prv_id IN NUMBER, p_numero_factura IN VARCHAR2,
                                  p_dias_credito IN NUMBER, p_pendiente IN VARCHAR2,
                                  p_lineas IN t_lineas_compra, p_cxp_id OUT NUMBER);
    PROCEDURE P_DEVOLVER_PROVEEDOR (p_prv_id IN NUMBER, p_cxp_id IN NUMBER, p_usr_id IN NUMBER,
                                    p_motivo IN VARCHAR2, p_nota_credito IN VARCHAR2,
                                    p_lineas IN t_lineas_dev_prv, p_dvp_id OUT NUMBER);
END PKG_COMPRAS;
/
CREATE OR REPLACE PACKAGE BODY PKG_COMPRAS AS

    -- Lo invoca el trigger de CXP_DETALLE: entrada a bodega central y control del costo
    PROCEDURE P_RECIBIR_LINEA (p_cxp_id IN NUMBER, p_lot_id IN NUMBER,
                               p_cantidad IN NUMBER, p_precio IN NUMBER) IS
        v_prd   PRODUCTO.PRD_ID%TYPE;
        v_costo PRODUCTO.PRD_PRECIO_COSTO%TYPE;
    BEGIN
        PKG_INVENTARIO.P_MOVER_CENTRAL(p_lot_id, p_cantidad, 'COMPRA', 'CXP-' || p_cxp_id);

        SELECT p.PRD_ID, p.PRD_PRECIO_COSTO INTO v_prd, v_costo
          FROM LOTE l JOIN PRODUCTO p ON p.PRD_ID = l.PRD_ID
         WHERE l.LOT_ID = p_lot_id;

        IF v_costo <> p_precio THEN               -- costo distinto al actual -> historial de precios
            PKG_PRECIOS.g_motivo := 'Nuevo costo por factura de proveedor (CXP ' || p_cxp_id || ')';
            UPDATE PRODUCTO SET PRD_PRECIO_COSTO = p_precio WHERE PRD_ID = v_prd;
            PKG_PRECIOS.g_motivo := NULL;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_PRECIOS.g_motivo := NULL;
            PKG_ERRORES.P_REGISTRAR('PKG_COMPRAS', 'P_RECIBIR_LINEA', SQLCODE, SQLERRM,
                                    'cxp=' || p_cxp_id || ' lote=' || p_lot_id);
            RAISE;
    END P_RECIBIR_LINEA;

    /* Registra una factura de proveedor completa en una sola transaccion:
       cabecera (CUENTA_POR_PAGAR), lotes y detalle. p_pendiente = 'S' deja la
       factura pendiente de pago (aumenta el saldo del proveedor y valida su limite);
       'N' la registra ya pagada (no aumenta el saldo). */
    PROCEDURE P_REGISTRAR_COMPRA (p_prv_id IN NUMBER, p_numero_factura IN VARCHAR2,
                                  p_dias_credito IN NUMBER, p_pendiente IN VARCHAR2,
                                  p_lineas IN t_lineas_compra, p_cxp_id OUT NUMBER) IS
        v_total  NUMBER := 0;
        v_hoy    DATE := TRUNC(SYSDATE);
        v_lot_id LOTE.LOT_ID%TYPE;
        v_numero LOTE.LOT_NUMERO%TYPE;
        v_prv_prd PRODUCTO.PRV_ID%TYPE;
        i PLS_INTEGER;
    BEGIN
        SAVEPOINT sp_compra;
        IF p_lineas IS NULL OR p_lineas.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20161, 'La factura de proveedor debe tener al menos una linea.');
        END IF;
        IF p_pendiente NOT IN ('S', 'N') THEN
            RAISE_APPLICATION_ERROR(-20161, 'p_pendiente debe ser S o N.');
        END IF;

        i := p_lineas.FIRST;
        WHILE i IS NOT NULL LOOP
            IF p_lineas(i).cantidad IS NULL OR p_lineas(i).cantidad <= 0 OR
               p_lineas(i).costo IS NULL OR p_lineas(i).costo < 0 THEN
                RAISE_APPLICATION_ERROR(-20161, 'Linea ' || i || ': cantidad o costo invalidos.');
            END IF;
            SELECT PRV_ID INTO v_prv_prd FROM PRODUCTO WHERE PRD_ID = p_lineas(i).prd_id;
            IF v_prv_prd <> p_prv_id THEN
                RAISE_APPLICATION_ERROR(-20161, 'Linea ' || i || ': el producto ' || p_lineas(i).prd_id ||
                                        ' no pertenece al proveedor ' || p_prv_id || '.');
            END IF;
            v_total := v_total + ROUND(p_lineas(i).cantidad * p_lineas(i).costo, 2);
            i := p_lineas.NEXT(i);
        END LOOP;

        -- Cabecera: el trigger valida el limite de credito y aumenta el saldo del proveedor
        INSERT INTO CUENTA_POR_PAGAR (PRV_ID, CXP_NUMERO_FACTURA, CXP_FECHA, CXP_FECHA_VENCIMIENTO,
                                      CXP_MONTO_TOTAL, CXP_SALDO, CXP_ESTADO)
        VALUES (p_prv_id, p_numero_factura, v_hoy, v_hoy + NVL(p_dias_credito, 30), v_total,
                CASE WHEN p_pendiente = 'S' THEN v_total ELSE 0 END,
                CASE WHEN p_pendiente = 'S' THEN 'PENDIENTE' ELSE 'PAGADA' END)
        RETURNING CXP_ID INTO p_cxp_id;

        i := p_lineas.FIRST;
        WHILE i IS NOT NULL LOOP
            v_numero := NVL(p_lineas(i).lote_numero,
                            'L-' || TO_CHAR(SYSDATE, 'YYYYMMDD') || '-' || SEQ_LOTE.NEXTVAL);
            INSERT INTO LOTE (PRD_ID, LOT_NUMERO, LOT_FECHA_INGRESO, LOT_FECHA_VENCIMIENTO,
                              LOT_COSTO_UNITARIO, LOT_CANTIDAD_INICIAL, LOT_ESTADO)
            VALUES (p_lineas(i).prd_id, v_numero, v_hoy, p_lineas(i).fecha_venc,
                    p_lineas(i).costo, p_lineas(i).cantidad, 'ACTIVO')
            RETURNING LOT_ID INTO v_lot_id;
            -- El trigger TRG_CXD_AIR aumenta el inventario central y controla el costo
            INSERT INTO CXP_DETALLE (CXP_ID, LOT_ID, CXD_CANTIDAD, CXD_PRECIO)
            VALUES (p_cxp_id, v_lot_id, p_lineas(i).cantidad, p_lineas(i).costo);
            i := p_lineas.NEXT(i);
        END LOOP;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_compra;
            p_cxp_id := NULL;
            PKG_ERRORES.P_REGISTRAR('PKG_COMPRAS', 'P_REGISTRAR_COMPRA', SQLCODE, SQLERRM,
                                    'prv=' || p_prv_id || ' factura=' || p_numero_factura);
            RAISE;
    END P_REGISTRAR_COMPRA;

    /* Devolucion de producto a un proveedor. Rebaja el inventario central (trigger de
       DVP_DETALLE). Si se indica la cuenta por pagar, la devolucion se aplica y baja el saldo. */
    PROCEDURE P_DEVOLVER_PROVEEDOR (p_prv_id IN NUMBER, p_cxp_id IN NUMBER, p_usr_id IN NUMBER,
                                    p_motivo IN VARCHAR2, p_nota_credito IN VARCHAR2,
                                    p_lineas IN t_lineas_dev_prv, p_dvp_id OUT NUMBER) IS
        v_total NUMBER := 0;
        v_costo NUMBER;
        i PLS_INTEGER;
    BEGIN
        SAVEPOINT sp_dev_prv;
        IF p_lineas IS NULL OR p_lineas.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20161, 'La devolucion debe tener al menos una linea.');
        END IF;

        i := p_lineas.FIRST;
        WHILE i IS NOT NULL LOOP
            SELECT LOT_COSTO_UNITARIO INTO v_costo FROM LOTE WHERE LOT_ID = p_lineas(i).lot_id;
            v_total := v_total + ROUND(p_lineas(i).cantidad * v_costo, 2);
            i := p_lineas.NEXT(i);
        END LOOP;

        INSERT INTO DEVOLUCION_PROVEEDOR (PRV_ID, CXP_ID, USR_ID, DVP_FECHA, DVP_MOTIVO,
                                          DVP_NOTA_CREDITO_PRV, DVP_MONTO, DVP_ESTADO)
        VALUES (p_prv_id, p_cxp_id, p_usr_id, SYSDATE, p_motivo, p_nota_credito, v_total, 'PENDIENTE')
        RETURNING DVP_ID INTO p_dvp_id;

        i := p_lineas.FIRST;
        WHILE i IS NOT NULL LOOP
            SELECT LOT_COSTO_UNITARIO INTO v_costo FROM LOTE WHERE LOT_ID = p_lineas(i).lot_id;
            -- El trigger TRG_DVD_AIR rebaja el inventario central
            INSERT INTO DVP_DETALLE (DVP_ID, LOT_ID, DVD_CANTIDAD, DVD_COSTO_UNITARIO)
            VALUES (p_dvp_id, p_lineas(i).lot_id, p_lineas(i).cantidad, v_costo);
            i := p_lineas.NEXT(i);
        END LOOP;

        IF p_cxp_id IS NOT NULL THEN              -- el trigger TRG_DVP_AIUR rebaja la cuenta por pagar
            UPDATE DEVOLUCION_PROVEEDOR SET DVP_ESTADO = 'APLICADA' WHERE DVP_ID = p_dvp_id;
        END IF;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_dev_prv;
            p_dvp_id := NULL;
            PKG_ERRORES.P_REGISTRAR('PKG_COMPRAS', 'P_DEVOLVER_PROVEEDOR', SQLCODE, SQLERRM,
                                    'prv=' || p_prv_id || ' cxp=' || p_cxp_id);
            RAISE;
    END P_DEVOLVER_PROVEEDOR;
END PKG_COMPRAS;
/
SHOW ERRORS

/* ============================================================================
   PKG_FACTURACION  -  facturas a clientes, anulacion y notas de credito
   P_FACTURAR calcula precios con VW_PRECIO_VENTA (+ descuentos automaticos por
   lote de DESCUENTO_PRODUCTO, limitados al maximo del producto en el negocio),
   inserta cabecera y lineas en una sola transaccion. Los triggers hacen el resto:
   limite de credito, cuenta por cobrar, saldo del cliente e inventario.
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_FACTURACION AS
    TYPE t_linea_fac IS RECORD (
        lot_id   NUMBER,      -- lote (producto) o NULL si es servicio
        srv_id   NUMBER,      -- servicio o NULL si es producto
        cantidad NUMBER);
    TYPE t_lineas_fac IS TABLE OF t_linea_fac INDEX BY PLS_INTEGER;

    TYPE t_linea_dev IS RECORD (
        fcd_id   NUMBER,      -- linea de la factura original
        cantidad NUMBER);
    TYPE t_lineas_dev IS TABLE OF t_linea_dev INDEX BY PLS_INTEGER;

    PROCEDURE P_FACTURAR (p_cli_id IN NUMBER, p_suc_id IN NUMBER, p_usr_id IN NUMBER,
                          p_tipo IN VARCHAR2, p_lineas IN t_lineas_fac,
                          p_fpg_id IN NUMBER DEFAULT NULL, p_referencia IN VARCHAR2 DEFAULT NULL,
                          p_fac_id OUT NUMBER);
    PROCEDURE P_ANULAR_FACTURA (p_fac_id IN NUMBER, p_motivo IN VARCHAR2 DEFAULT NULL);
    PROCEDURE P_DEVOLVER_CLIENTE (p_fac_id IN NUMBER, p_usr_id IN NUMBER, p_motivo IN VARCHAR2,
                                  p_lineas IN t_lineas_dev, p_ntc_id OUT NUMBER);
END PKG_FACTURACION;
/
CREATE OR REPLACE PACKAGE BODY PKG_FACTURACION AS
    e_ocupado_nowait EXCEPTION;
    e_ocupado_wait   EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_ocupado_nowait, -54);
    PRAGMA EXCEPTION_INIT(e_ocupado_wait,   -30006);

    PROCEDURE P_FACTURAR (p_cli_id IN NUMBER, p_suc_id IN NUMBER, p_usr_id IN NUMBER,
                          p_tipo IN VARCHAR2, p_lineas IN t_lineas_fac,
                          p_fpg_id IN NUMBER DEFAULT NULL, p_referencia IN VARCHAR2 DEFAULT NULL,
                          p_fac_id OUT NUMBER) IS
        TYPE t_calc IS RECORD (lot_id NUMBER, srv_id NUMBER, cantidad NUMBER,
                               precio NUMBER, descuento NUMBER, impuesto NUMBER);
        TYPE t_calcs IS TABLE OF t_calc INDEX BY PLS_INTEGER;
        v_calc    t_calcs;
        v_neg     SUCURSAL.NEG_ID%TYPE;
        v_cli     CLIENTE.CLI_ID%TYPE;
        v_prd     PRODUCTO.PRD_ID%TYPE;
        v_lot_est LOTE.LOT_ESTADO%TYPE;
        v_lot_ven LOTE.LOT_FECHA_VENCIMIENTO%TYPE;
        v_base NUMBER; v_tasa NUMBER; v_pct_vista NUMBER; v_pct_max NUMBER; v_pct_lote NUMBER; v_pct NUMBER;
        v_bruto NUMBER; v_desc NUMBER; v_imp NUMBER;
        v_sub NUMBER := 0; v_des_tot NUMBER := 0; v_imp_tot NUMBER := 0; v_total NUMBER;
        v_numero VARCHAR2(20);
        v_id     FACTURA.FAC_ID%TYPE;
        i PLS_INTEGER;
    BEGIN
        SAVEPOINT sp_facturar;

        IF p_lineas IS NULL OR p_lineas.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20170, 'La factura debe tener al menos una linea.');
        END IF;
        IF p_tipo NOT IN ('CONTADO', 'CREDITO') THEN
            RAISE_APPLICATION_ERROR(-20170, 'Tipo de factura invalido: ' || p_tipo);
        END IF;
        IF p_tipo = 'CONTADO' AND p_fpg_id IS NULL THEN
            RAISE_APPLICATION_ERROR(-20172, 'Una factura de contado requiere la forma de pago.');
        END IF;

        SELECT NEG_ID INTO v_neg FROM SUCURSAL WHERE SUC_ID = p_suc_id AND SUC_ESTADO = 'A';
        -- sin cliente registrado se usa el cliente por defecto
        IF p_cli_id IS NULL THEN
            SELECT CLI_ID INTO v_cli FROM CLIENTE WHERE CLI_ES_DEFECTO = 'S';
        ELSE
            v_cli := p_cli_id;
        END IF;

        -- 1) Calculo de precios, descuentos e impuestos por linea
        i := p_lineas.FIRST;
        WHILE i IS NOT NULL LOOP
            IF p_lineas(i).cantidad IS NULL OR p_lineas(i).cantidad <= 0 THEN
                RAISE_APPLICATION_ERROR(-20170, 'Linea ' || i || ': la cantidad debe ser mayor que cero.');
            END IF;
            IF (p_lineas(i).lot_id IS NULL) = (p_lineas(i).srv_id IS NULL) THEN
                RAISE_APPLICATION_ERROR(-20170, 'Linea ' || i || ': indique un lote o un servicio, no ambos.');
            END IF;

            v_calc(i).lot_id := p_lineas(i).lot_id;
            v_calc(i).srv_id := p_lineas(i).srv_id;
            v_calc(i).cantidad := p_lineas(i).cantidad;

            IF p_lineas(i).lot_id IS NOT NULL THEN
                SELECT PRD_ID, LOT_ESTADO, LOT_FECHA_VENCIMIENTO INTO v_prd, v_lot_est, v_lot_ven
                  FROM LOTE WHERE LOT_ID = p_lineas(i).lot_id;
                IF v_lot_est <> 'ACTIVO' OR (v_lot_ven IS NOT NULL AND v_lot_ven < TRUNC(SYSDATE)) THEN
                    RAISE_APPLICATION_ERROR(-20171, 'Linea ' || i || ': el lote ' || p_lineas(i).lot_id ||
                                            ' esta vencido, agotado o bloqueado.');
                END IF;
                SELECT v.PRECIO_BASE, v.TASA_IMPUESTO, v.PORC_DESCUENTO, pn.PRN_PORC_DESC_MAX
                  INTO v_base, v_tasa, v_pct_vista, v_pct_max
                  FROM VW_PRECIO_VENTA v
                  JOIN PRODUCTO_NEGOCIO pn ON pn.PRD_ID = v.PRD_ID AND pn.NEG_ID = v.NEG_ID
                 WHERE v.PRD_ID = v_prd AND v.NEG_ID = v_neg;
                -- descuento automatico del lote (proximo a vencer / antiguedad), limitado al maximo permitido
                SELECT NVL(MAX(DSP_PORCENTAJE), 0) INTO v_pct_lote
                  FROM DESCUENTO_PRODUCTO WHERE LOT_ID = p_lineas(i).lot_id AND DSP_ESTADO = 'A';
                v_pct   := LEAST(v_pct_max, GREATEST(v_pct_vista, v_pct_lote));
                v_bruto := ROUND(v_base * p_lineas(i).cantidad, 2);
                v_desc  := ROUND(v_bruto * v_pct / 100, 2);
            ELSE
                SELECT s.SRV_PRECIO, NVL(im.IMP_TASA, 0) INTO v_base, v_tasa
                  FROM SERVICIO s LEFT JOIN IMPUESTO im ON im.IMP_ID = s.IMP_ID
                 WHERE s.SRV_ID = p_lineas(i).srv_id AND s.SRV_ESTADO = 'A';
                v_bruto := ROUND(v_base * p_lineas(i).cantidad, 2);
                v_desc  := 0;
            END IF;
            v_imp := ROUND((v_bruto - v_desc) * v_tasa / 100, 2);

            v_calc(i).precio := v_base;
            v_calc(i).descuento := v_desc;
            v_calc(i).impuesto := v_imp;
            v_sub     := v_sub + v_bruto;
            v_des_tot := v_des_tot + v_desc;
            v_imp_tot := v_imp_tot + v_imp;
            i := p_lineas.NEXT(i);
        END LOOP;
        v_total := v_sub - v_des_tot + v_imp_tot;

        -- 2) Cabecera. Estado NULL: el trigger lo define (CREDITO = PENDIENTE, CONTADO = CANCELADA),
        --    valida el limite de credito, crea la cuenta por cobrar y aumenta el saldo del cliente.
        v_id := SEQ_FACTURA.NEXTVAL;
        v_numero := 'FE-' || LPAD(v_id, 6, '0');
        INSERT INTO FACTURA (FAC_ID, FAC_NUMERO, FAC_FECHA, FAC_TIPO, CLI_ID, SUC_ID, USR_ID,
                             FAC_SUBTOTAL, FAC_DESCUENTO, FAC_IMPUESTO, FAC_TOTAL, FAC_ESTADO)
        VALUES (v_id, v_numero, SYSDATE, p_tipo, v_cli, p_suc_id, p_usr_id,
                v_sub, v_des_tot, v_imp_tot, v_total, NULL);

        -- 3) Lineas. El trigger TRG_FCD_AIR descuenta el inventario de la sucursal.
        i := v_calc.FIRST;
        WHILE i IS NOT NULL LOOP
            INSERT INTO FAC_DETALLE (FAC_ID, LOT_ID, SRV_ID, FCD_CANTIDAD, FCD_PRECIO, FCD_DESCUENTO, FCD_IMPUESTO)
            VALUES (v_id, v_calc(i).lot_id, v_calc(i).srv_id, v_calc(i).cantidad,
                    v_calc(i).precio, v_calc(i).descuento, v_calc(i).impuesto);
            i := v_calc.NEXT(i);
        END LOOP;

        -- 4) Pago de contado
        IF p_tipo = 'CONTADO' THEN
            INSERT INTO FAC_PAGO (FAC_ID, FPG_ID, PAG_MONTO, PAG_REFERENCIA)
            VALUES (v_id, p_fpg_id, v_total, p_referencia);
        END IF;

        p_fac_id := v_id;
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK TO sp_facturar;
            p_fac_id := NULL;
            PKG_ERRORES.P_REGISTRAR('PKG_FACTURACION', 'P_FACTURAR', SQLCODE,
                'Dato inexistente (sucursal, cliente, lote, servicio o producto sin configurar en el negocio)',
                'cli=' || p_cli_id || ' suc=' || p_suc_id);
            RAISE_APPLICATION_ERROR(-20171, 'Dato inexistente: verifique sucursal, cliente, lote, servicio ' ||
                                    'y que el producto este configurado en el negocio.');
        WHEN OTHERS THEN
            ROLLBACK TO sp_facturar;
            p_fac_id := NULL;
            PKG_ERRORES.P_REGISTRAR('PKG_FACTURACION', 'P_FACTURAR', SQLCODE, SQLERRM,
                                    'cli=' || p_cli_id || ' suc=' || p_suc_id || ' tipo=' || p_tipo);
            RAISE;
    END P_FACTURAR;

    -- Anula una factura: devuelve el stock y anula la cuenta por cobrar (trigger TRG_FAC_AUR)
    PROCEDURE P_ANULAR_FACTURA (p_fac_id IN NUMBER, p_motivo IN VARCHAR2 DEFAULT NULL) IS
        v_estado FACTURA.FAC_ESTADO%TYPE;
        v_abonos NUMBER;
    BEGIN
        SAVEPOINT sp_anular;
        -- NOWAIT: si otra sesion esta procesando la factura se informa de inmediato
        SELECT FAC_ESTADO INTO v_estado FROM FACTURA WHERE FAC_ID = p_fac_id FOR UPDATE NOWAIT;
        IF v_estado NOT IN ('PENDIENTE', 'CANCELADA') THEN
            RAISE_APPLICATION_ERROR(-20173, 'La factura ' || p_fac_id || ' esta ' || v_estado || ' y no se puede anular.');
        END IF;
        SELECT COUNT(*) INTO v_abonos
          FROM CXC_ABONO a JOIN CUENTA_POR_COBRAR c ON c.CXC_ID = a.CXC_ID WHERE c.FAC_ID = p_fac_id;
        IF v_abonos > 0 THEN
            RAISE_APPLICATION_ERROR(-20174, 'La factura ' || p_fac_id ||
                                    ' tiene abonos aplicados: utilice una nota de credito.');
        END IF;
        UPDATE FACTURA SET FAC_ESTADO = 'ANULADA' WHERE FAC_ID = p_fac_id;
        COMMIT;
    EXCEPTION
        WHEN e_ocupado_nowait THEN
            ROLLBACK TO sp_anular;
            PKG_ERRORES.P_REGISTRAR('PKG_FACTURACION', 'P_ANULAR_FACTURA', SQLCODE, SQLERRM, 'fac=' || p_fac_id);
            RAISE_APPLICATION_ERROR(-20190, 'La factura ' || p_fac_id || ' esta siendo procesada por otra sesion.');
        WHEN OTHERS THEN
            ROLLBACK TO sp_anular;
            PKG_ERRORES.P_REGISTRAR('PKG_FACTURACION', 'P_ANULAR_FACTURA', SQLCODE, SQLERRM, 'fac=' || p_fac_id);
            RAISE;
    END P_ANULAR_FACTURA;

    -- Devolucion (total o parcial) de una factura de cliente mediante nota de credito
    PROCEDURE P_DEVOLVER_CLIENTE (p_fac_id IN NUMBER, p_usr_id IN NUMBER, p_motivo IN VARCHAR2,
                                  p_lineas IN t_lineas_dev, p_ntc_id OUT NUMBER) IS
        v_estado  FACTURA.FAC_ESTADO%TYPE;
        v_cant_o  NUMBER; v_precio NUMBER; v_desc NUMBER; v_imp NUMBER; v_ya NUMBER;
        v_monto_l NUMBER; v_monto NUMBER := 0; v_cant_nueva NUMBER := 0;
        v_cant_fac NUMBER; v_cant_prev NUMBER;
        v_tipo VARCHAR2(10);
        v_id   NOTA_CREDITO.NTC_ID%TYPE;
        TYPE t_montos IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
        v_montos t_montos;
        i PLS_INTEGER;
    BEGIN
        SAVEPOINT sp_dev_cli;
        IF p_lineas IS NULL OR p_lineas.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20175, 'La devolucion debe tener al menos una linea.');
        END IF;
        EXECUTE IMMEDIATE 'SELECT FAC_ESTADO FROM FACTURA WHERE FAC_ID = :1 FOR UPDATE WAIT '
                          || PKG_UTIL.F_ESPERA_BLOQUEO INTO v_estado USING p_fac_id;
        IF v_estado NOT IN ('PENDIENTE', 'CANCELADA') THEN
            RAISE_APPLICATION_ERROR(-20173, 'La factura ' || p_fac_id || ' esta ' || v_estado ||
                                    ': no admite devoluciones.');
        END IF;

        i := p_lineas.FIRST;
        WHILE i IS NOT NULL LOOP
            SELECT FCD_CANTIDAD, FCD_PRECIO, FCD_DESCUENTO, FCD_IMPUESTO INTO v_cant_o, v_precio, v_desc, v_imp
              FROM FAC_DETALLE WHERE FCD_ID = p_lineas(i).fcd_id AND FAC_ID = p_fac_id;
            SELECT NVL(SUM(d.NTD_CANTIDAD), 0) INTO v_ya
              FROM NTC_DETALLE d JOIN NOTA_CREDITO n ON n.NTC_ID = d.NTC_ID
             WHERE d.FCD_ID = p_lineas(i).fcd_id AND n.NTC_ESTADO = 'APLICADA';
            IF p_lineas(i).cantidad <= 0 OR p_lineas(i).cantidad > v_cant_o - v_ya THEN
                RAISE_APPLICATION_ERROR(-20175, 'Linea ' || p_lineas(i).fcd_id || ': solo se pueden devolver ' ||
                                        (v_cant_o - v_ya) || ' unidades.');
            END IF;
            -- monto proporcional (incluye descuento e impuesto de la linea)
            v_monto_l := ROUND((v_cant_o * v_precio - v_desc + v_imp) * p_lineas(i).cantidad / v_cant_o, 2);
            IF v_monto_l <= 0 THEN
                RAISE_APPLICATION_ERROR(-20175, 'Linea ' || p_lineas(i).fcd_id || ': monto a acreditar invalido.');
            END IF;
            v_montos(i) := v_monto_l;
            v_monto := v_monto + v_monto_l;
            v_cant_nueva := v_cant_nueva + p_lineas(i).cantidad;
            i := p_lineas.NEXT(i);
        END LOOP;

        -- TOTAL si, con esta nota, quedo devuelta toda la factura
        SELECT NVL(SUM(FCD_CANTIDAD), 0) INTO v_cant_fac FROM FAC_DETALLE WHERE FAC_ID = p_fac_id;
        SELECT NVL(SUM(d.NTD_CANTIDAD), 0) INTO v_cant_prev
          FROM NTC_DETALLE d JOIN NOTA_CREDITO n ON n.NTC_ID = d.NTC_ID
         WHERE n.FAC_ID = p_fac_id AND n.NTC_ESTADO = 'APLICADA';
        v_tipo := CASE WHEN v_cant_prev + v_cant_nueva = v_cant_fac THEN 'TOTAL' ELSE 'PARCIAL' END;

        v_id := SEQ_NOTA_CREDITO.NEXTVAL;
        -- El trigger TRG_NTC_AIR rebaja la cuenta por cobrar / marca la factura DEVUELTA
        INSERT INTO NOTA_CREDITO (NTC_ID, NTC_NUMERO, FAC_ID, USR_ID, NTC_FECHA, NTC_TIPO,
                                  NTC_MOTIVO, NTC_MONTO, NTC_ESTADO)
        VALUES (v_id, 'NC-' || LPAD(v_id, 6, '0'), p_fac_id, p_usr_id, SYSDATE, v_tipo,
                p_motivo, v_monto, 'APLICADA');

        i := p_lineas.FIRST;
        WHILE i IS NOT NULL LOOP
            -- El trigger TRG_NTD_AIR devuelve el stock a la sucursal
            INSERT INTO NTC_DETALLE (NTC_ID, FCD_ID, NTD_CANTIDAD, NTD_MONTO)
            VALUES (v_id, p_lineas(i).fcd_id, p_lineas(i).cantidad, v_montos(i));
            i := p_lineas.NEXT(i);
        END LOOP;
        p_ntc_id := v_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_dev_cli;
            p_ntc_id := NULL;
            PKG_ERRORES.P_REGISTRAR('PKG_FACTURACION', 'P_DEVOLVER_CLIENTE', SQLCODE, SQLERRM, 'fac=' || p_fac_id);
            RAISE;
    END P_DEVOLVER_CLIENTE;
END PKG_FACTURACION;
/
SHOW ERRORS

/* ============================== FIN DEL SCRIPT ============================== */
