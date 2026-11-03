/* ============================================================================
   UNIVERSIDAD NACIONAL - SEDE REGIONAL BRUNCA - CAMPUS PZ/COTO
   CURSO: ADMINISTRACION DE BASE DE DATOS - II CICLO 2026
   PROYECTO FINAL - ENTREGABLE #2 - PARTE A
   ARCHIVO: 10_paquetes_procesos.sql   (ENTREGA 2: procesos automaticos y notificaciones)
   REVISION: el ROLLBACK TO savepoint de los manejadores de excepciones se protege (ORA-01086 tras un COMMIT).
   ----------------------------------------------------------------------------
   MODULOS:
     PKG_PROCESOS       Control de ejecucion de procesos (PROCESO_LOG)
     PKG_NOTIF_NEGOCIO  UNICO punto de salida de correos (enlace con la Parte B)
     PKG_PROMOCIONES    Acciones por productos patrocinadores
     PKG_DESCUENTOS     Descuentos programados (proximo a vencer / antiguedad)
     PKG_MERCADEO       Reporte semanal (por vencer / antiguos) y vencidos
     PKG_PREMIOS        Mejores clientes (orden de compra)
     PKG_CIERRE         Cierre diario
     PKG_NOTIFICACIONES Alertas de limites de credito y morosidad
   ENLACE CON LA PARTE B: PKG_NOTIF_NEGOCIO llama por SQL dinamico a
        PKG_CORREO.ENVIAR(p_destinatarios VARCHAR2, p_asunto VARCHAR2, p_mensaje CLOB)
   cuando el parametro NOTIF_MODO = 'REAL'. Si el paquete de la Parte B tiene otra
   firma, solo se cambia la linea marcada "ENLACE PARTE B". En modo 'SIMULADO'
   todo queda registrado en NOTIFICACION_LOG sin enviar correo.
   ============================================================================ */
ALTER SESSION SET CURRENT_SCHEMA = SUM_ADMIN;

-- Existencia total por lote (central + sucursales)
CREATE OR REPLACE VIEW VW_STOCK_LOTE AS
SELECT l.LOT_ID,
       NVL(c.CANT, 0) AS STOCK_CENTRAL,
       NVL(s.CANT, 0) AS STOCK_SUCURSALES,
       NVL(c.CANT, 0) + NVL(s.CANT, 0) AS STOCK_TOTAL
  FROM LOTE l
  LEFT JOIN (SELECT LOT_ID, SUM(INC_CANTIDAD) CANT FROM INVENTARIO_CENTRAL GROUP BY LOT_ID) c ON c.LOT_ID = l.LOT_ID
  LEFT JOIN (SELECT LOT_ID, SUM(INS_CANTIDAD) CANT FROM INVENTARIO_SUCURSAL GROUP BY LOT_ID) s ON s.LOT_ID = l.LOT_ID;
COMMENT ON TABLE VW_STOCK_LOTE IS 'Existencia por lote: bodega central, sucursales y total.';

/* ============================================================================
   PKG_PROCESOS
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_PROCESOS AS
    FUNCTION  F_INICIAR (p_proceso IN VARCHAR2) RETURN NUMBER;
    PROCEDURE P_FINALIZAR (p_id IN NUMBER, p_estado IN VARCHAR2, p_mensaje IN VARCHAR2 DEFAULT NULL);
    FUNCTION  F_ULTIMA_EJECUCION_OK (p_proceso IN VARCHAR2) RETURN DATE;
END PKG_PROCESOS;
/
CREATE OR REPLACE PACKAGE BODY PKG_PROCESOS AS
    FUNCTION F_INICIAR (p_proceso IN VARCHAR2) RETURN NUMBER IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_id PROCESO_LOG.PRL_ID%TYPE;
    BEGIN
        INSERT INTO PROCESO_LOG (PRL_PROCESO) VALUES (p_proceso) RETURNING PRL_ID INTO v_id;
        COMMIT;
        RETURN v_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            PKG_ERRORES.P_REGISTRAR('PKG_PROCESOS', 'F_INICIAR', SQLCODE, SQLERRM, p_proceso);
            RAISE;
    END F_INICIAR;

    PROCEDURE P_FINALIZAR (p_id IN NUMBER, p_estado IN VARCHAR2, p_mensaje IN VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE PROCESO_LOG SET PRL_FIN = SYSDATE, PRL_ESTADO = p_estado,
               PRL_MENSAJE = SUBSTR(p_mensaje, 1, 1000)
         WHERE PRL_ID = p_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            PKG_ERRORES.P_REGISTRAR('PKG_PROCESOS', 'P_FINALIZAR', SQLCODE, SQLERRM, 'id=' || p_id);
    END P_FINALIZAR;

    FUNCTION F_ULTIMA_EJECUCION_OK (p_proceso IN VARCHAR2) RETURN DATE IS
        v_fecha DATE;
    BEGIN
        SELECT MAX(PRL_INICIO) INTO v_fecha FROM PROCESO_LOG
         WHERE PRL_PROCESO = p_proceso AND PRL_ESTADO = 'OK';
        RETURN v_fecha;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_PROCESOS', 'F_ULTIMA_EJECUCION_OK', SQLCODE, SQLERRM, p_proceso);
            RAISE;
    END F_ULTIMA_EJECUCION_OK;
END PKG_PROCESOS;
/

/* ============================================================================
   PKG_NOTIF_NEGOCIO  -  unico punto de salida de notificaciones
   Destinatarios: grupos (GERENTE, COORDINADOR) de DESTINATARIO_NOTIF o una lista
   explicita. Si NOTIF_CORREO_REDIRIGIR tiene valor, TODO va a ese correo (defensa).
   Se registra siempre en NOTIFICACION_LOG (transaccion autonoma).
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_NOTIF_NEGOCIO AS
    PROCEDURE P_ENVIAR (p_tipo IN VARCHAR2, p_grupos IN VARCHAR2, p_asunto IN VARCHAR2,
                        p_mensaje IN CLOB, p_destinos IN VARCHAR2 DEFAULT NULL);
END PKG_NOTIF_NEGOCIO;
/
CREATE OR REPLACE PACKAGE BODY PKG_NOTIF_NEGOCIO AS
    PROCEDURE P_ENVIAR (p_tipo IN VARCHAR2, p_grupos IN VARCHAR2, p_asunto IN VARCHAR2,
                        p_mensaje IN CLOB, p_destinos IN VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_dest   VARCHAR2(1000);
        v_redir  VARCHAR2(200);
        v_estado VARCHAR2(10);
        v_error  VARCHAR2(500);
    BEGIN
        v_redir := PKG_PARAMETROS.F_VALOR('NOTIF_CORREO_REDIRIGIR');
        IF v_redir IS NOT NULL THEN
            v_dest := v_redir;
        ELSIF p_destinos IS NOT NULL THEN
            v_dest := p_destinos;
        ELSE
            SELECT LISTAGG(DNT_EMAIL, ',') WITHIN GROUP (ORDER BY DNT_EMAIL) INTO v_dest
              FROM DESTINATARIO_NOTIF
             WHERE DNT_ESTADO = 'A' AND INSTR(',' || p_grupos || ',', ',' || DNT_GRUPO || ',') > 0;
        END IF;

        IF v_dest IS NULL THEN
            v_estado := 'ERROR';
            v_error  := 'Sin destinatarios para ' || NVL(p_grupos, 'el mensaje');
        ELSIF UPPER(NVL(PKG_PARAMETROS.F_VALOR('NOTIF_MODO'), 'SIMULADO')) = 'REAL' THEN
            BEGIN
                -- ENLACE PARTE B: paquete de correo (UTL_SMTP/UTL_MAIL) directo desde Oracle
                EXECUTE IMMEDIATE 'BEGIN PKG_CORREO.ENVIAR(:d, :a, :m); END;'
                    USING v_dest, p_asunto, p_mensaje;
                v_estado := 'ENVIADO';
            EXCEPTION
                WHEN OTHERS THEN
                    v_estado := 'ERROR';
                    v_error  := SUBSTR(SQLERRM, 1, 500);
                    PKG_ERRORES.P_REGISTRAR('PKG_NOTIF_NEGOCIO', 'P_ENVIAR', SQLCODE, SQLERRM, p_tipo);
            END;
        ELSE
            v_estado := 'SIMULADO';
        END IF;

        INSERT INTO NOTIFICACION_LOG (NTL_TIPO, NTL_DESTINATARIOS, NTL_ASUNTO, NTL_MENSAJE, NTL_ESTADO, NTL_ERROR)
        VALUES (SUBSTR(p_tipo, 1, 40), NVL(SUBSTR(v_dest, 1, 1000), '(sin destinatario)'),
                SUBSTR(p_asunto, 1, 200), p_mensaje, v_estado, v_error);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            PKG_ERRORES.P_REGISTRAR('PKG_NOTIF_NEGOCIO', 'P_ENVIAR', SQLCODE, SQLERRM, p_tipo);
            RAISE;
    END P_ENVIAR;
END PKG_NOTIF_NEGOCIO;
/

/* ============================================================================
   PKG_PROMOCIONES  -  acciones segun productos patrocinadores comprados
   Formula: acciones = TRUNC(cantidad patrocinadores / PRM_CANT_REQUERIDA) x PRM_CANT_ACCIONES
   (la cantidad requerida vive en la propia tabla PROMOCION). El resultado queda en
   PROMOCION_CLIENTE y se recalcula solo al insertar lineas de factura.
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_PROMOCIONES AS
    FUNCTION  F_ACCIONES (p_prm_id IN NUMBER, p_cantidad IN NUMBER) RETURN NUMBER;
    PROCEDURE P_CALCULAR_FACTURA (p_fac_id IN NUMBER);
END PKG_PROMOCIONES;
/
CREATE OR REPLACE PACKAGE BODY PKG_PROMOCIONES AS
    FUNCTION F_ACCIONES (p_prm_id IN NUMBER, p_cantidad IN NUMBER) RETURN NUMBER IS
        v_req PROMOCION.PRM_CANT_REQUERIDA%TYPE;
        v_acc PROMOCION.PRM_CANT_ACCIONES%TYPE;
    BEGIN
        SELECT PRM_CANT_REQUERIDA, PRM_CANT_ACCIONES INTO v_req, v_acc FROM PROMOCION WHERE PRM_ID = p_prm_id;
        RETURN TRUNC(NVL(p_cantidad, 0) / v_req) * v_acc;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_PROMOCIONES', 'F_ACCIONES', SQLCODE, SQLERRM, 'prm=' || p_prm_id);
            RAISE;
    END F_ACCIONES;

    PROCEDURE P_CALCULAR_FACTURA (p_fac_id IN NUMBER) IS
    BEGIN
        DELETE FROM PROMOCION_CLIENTE WHERE FAC_ID = p_fac_id;
        FOR r IN (SELECT p.PRM_ID, f.CLI_ID, SUM(d.FCD_CANTIDAD) AS CANT
                    FROM FACTURA f
                    JOIN FAC_DETALLE d ON d.FAC_ID = f.FAC_ID
                    JOIN LOTE l ON l.LOT_ID = d.LOT_ID
                    JOIN PRM_PRODUCTO_PATROCINADOR pp ON pp.PRD_ID = l.PRD_ID
                    JOIN PROMOCION p ON p.PRM_ID = pp.PRM_ID
                   WHERE f.FAC_ID = p_fac_id
                     AND f.FAC_ESTADO IN ('PENDIENTE', 'CANCELADA')
                     AND p.PRM_ESTADO = 'A'
                     AND TRUNC(f.FAC_FECHA) BETWEEN p.PRM_FECHA_INICIO AND p.PRM_FECHA_FIN
                   GROUP BY p.PRM_ID, f.CLI_ID) LOOP
            INSERT INTO PROMOCION_CLIENTE (PRM_ID, FAC_ID, CLI_ID, PMC_CANT_PATROCINADORES, PMC_ACCIONES)
            VALUES (r.PRM_ID, p_fac_id, r.CLI_ID, r.CANT, F_ACCIONES(r.PRM_ID, r.CANT));
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_PROMOCIONES', 'P_CALCULAR_FACTURA', SQLCODE, SQLERRM, 'fac=' || p_fac_id);
            RAISE;
    END P_CALCULAR_FACTURA;
END PKG_PROMOCIONES;
/
-- Compound trigger: junta las facturas tocadas y calcula al final de la sentencia (evita ORA-04091)
CREATE OR REPLACE TRIGGER TRG_FCD_PROMO
FOR INSERT ON FAC_DETALLE
COMPOUND TRIGGER
    TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    g_ids t_ids;
    AFTER EACH ROW IS
    BEGIN
        g_ids(:NEW.FAC_ID) := :NEW.FAC_ID;
    END AFTER EACH ROW;
    AFTER STATEMENT IS
        i PLS_INTEGER;
    BEGIN
        i := g_ids.FIRST;
        WHILE i IS NOT NULL LOOP
            PKG_PROMOCIONES.P_CALCULAR_FACTURA(g_ids(i));
            i := g_ids.NEXT(i);
        END LOOP;
        g_ids.DELETE;
    END AFTER STATEMENT;
END TRG_FCD_PROMO;
/

/* ============================================================================
   PKG_DESCUENTOS  -  verificacion semanal de descuentos planeados
   Incluye al detalle (DESCUENTO_PRODUCTO) los lotes que cumplen los descuentos
   PROXIMO_VENCIMIENTO (DES_DIAS antes de vencer) y FECHA_INGRESO (antiguedad
   >= DES_DIAS). Retira los que dejan de cumplir. P_FACTURAR los aplica al vender.
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_DESCUENTOS AS
    PROCEDURE P_APLICAR_PROGRAMADOS;
END PKG_DESCUENTOS;
/
CREATE OR REPLACE PACKAGE BODY PKG_DESCUENTOS AS
    PROCEDURE P_APLICAR_PROGRAMADOS IS
        v_prl NUMBER; v_venc NUMBER := 0; v_ing NUMBER := 0; v_ret NUMBER := 0;
    BEGIN
        SAVEPOINT sp_descuentos;
        v_prl := PKG_PROCESOS.F_INICIAR('PKG_DESCUENTOS.P_APLICAR_PROGRAMADOS');

        -- a) productos cerca de vencer
        MERGE INTO DESCUENTO_PRODUCTO t
        USING (SELECT d.DES_ID, l.LOT_ID, d.DES_PORCENTAJE
                 FROM DESCUENTO d
                 JOIN LOTE l ON l.LOT_FECHA_VENCIMIENTO BETWEEN TRUNC(SYSDATE) AND TRUNC(SYSDATE) + d.DES_DIAS
                 JOIN VW_STOCK_LOTE sl ON sl.LOT_ID = l.LOT_ID
                WHERE d.DES_TIPO = 'PROXIMO_VENCIMIENTO' AND d.DES_ESTADO = 'A'
                  AND TRUNC(SYSDATE) BETWEEN d.DES_FECHA_INICIO AND d.DES_FECHA_FIN
                  AND l.LOT_ESTADO = 'ACTIVO' AND sl.STOCK_TOTAL > 0) s
           ON (t.DES_ID = s.DES_ID AND t.LOT_ID = s.LOT_ID)
         WHEN MATCHED THEN UPDATE SET t.DSP_ESTADO = 'A', t.DSP_PORCENTAJE = s.DES_PORCENTAJE
              WHERE t.DSP_ESTADO = 'I' OR t.DSP_PORCENTAJE <> s.DES_PORCENTAJE
         WHEN NOT MATCHED THEN INSERT (DES_ID, LOT_ID, DSP_PORCENTAJE, DSP_FECHA_ASIGNACION, DSP_ESTADO)
              VALUES (s.DES_ID, s.LOT_ID, s.DES_PORCENTAJE, SYSDATE, 'A');
        v_venc := SQL%ROWCOUNT;

        -- b) productos con mucha antiguedad en bodega
        MERGE INTO DESCUENTO_PRODUCTO t
        USING (SELECT d.DES_ID, l.LOT_ID, d.DES_PORCENTAJE
                 FROM DESCUENTO d
                 JOIN LOTE l ON l.LOT_FECHA_INGRESO <= TRUNC(SYSDATE) - d.DES_DIAS
                 JOIN VW_STOCK_LOTE sl ON sl.LOT_ID = l.LOT_ID
                WHERE d.DES_TIPO = 'FECHA_INGRESO' AND d.DES_ESTADO = 'A'
                  AND TRUNC(SYSDATE) BETWEEN d.DES_FECHA_INICIO AND d.DES_FECHA_FIN
                  AND l.LOT_ESTADO = 'ACTIVO' AND sl.STOCK_TOTAL > 0) s
           ON (t.DES_ID = s.DES_ID AND t.LOT_ID = s.LOT_ID)
         WHEN MATCHED THEN UPDATE SET t.DSP_ESTADO = 'A', t.DSP_PORCENTAJE = s.DES_PORCENTAJE
              WHERE t.DSP_ESTADO = 'I' OR t.DSP_PORCENTAJE <> s.DES_PORCENTAJE
         WHEN NOT MATCHED THEN INSERT (DES_ID, LOT_ID, DSP_PORCENTAJE, DSP_FECHA_ASIGNACION, DSP_ESTADO)
              VALUES (s.DES_ID, s.LOT_ID, s.DES_PORCENTAJE, SYSDATE, 'A');
        v_ing := SQL%ROWCOUNT;

        -- c) retira lotes que ya no califican (descuento vencido/inactivo, sin stock o lote vencido)
        UPDATE DESCUENTO_PRODUCTO t SET DSP_ESTADO = 'I'
         WHERE DSP_ESTADO = 'A'
           AND (NOT EXISTS (SELECT 1 FROM DESCUENTO d WHERE d.DES_ID = t.DES_ID AND d.DES_ESTADO = 'A'
                               AND TRUNC(SYSDATE) BETWEEN d.DES_FECHA_INICIO AND d.DES_FECHA_FIN)
                OR EXISTS (SELECT 1 FROM VW_STOCK_LOTE sl WHERE sl.LOT_ID = t.LOT_ID AND sl.STOCK_TOTAL = 0)
                OR EXISTS (SELECT 1 FROM LOTE l WHERE l.LOT_ID = t.LOT_ID AND l.LOT_FECHA_VENCIMIENTO < TRUNC(SYSDATE)));
        v_ret := SQL%ROWCOUNT;

        COMMIT;
        PKG_PROCESOS.P_FINALIZAR(v_prl, 'OK', 'Por vencer: ' || v_venc || ' | Antiguedad: ' || v_ing || ' | Retirados: ' || v_ret);
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN ROLLBACK TO sp_descuentos; EXCEPTION WHEN OTHERS THEN NULL; END;   -- si ya hubo COMMIT el savepoint no existe (ORA-01086); no se oculta el error original
            PKG_ERRORES.P_REGISTRAR('PKG_DESCUENTOS', 'P_APLICAR_PROGRAMADOS', SQLCODE, SQLERRM);
            IF v_prl IS NOT NULL THEN PKG_PROCESOS.P_FINALIZAR(v_prl, 'ERROR', SQLERRM); END IF;
            RAISE;
    END P_APLICAR_PROGRAMADOS;
END PKG_DESCUENTOS;
/

/* ============================================================================
   PKG_MERCADEO  -  reportes para el coordinador
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_MERCADEO AS
    PROCEDURE P_REPORTE_SEMANAL;       -- por vencer (7 dias) y mas de 6 meses en bodega, por separado
    PROCEDURE P_NOTIFICAR_VENCIDOS;    -- lista de vencidos con total
END PKG_MERCADEO;
/
CREATE OR REPLACE PACKAGE BODY PKG_MERCADEO AS
    CRLF CONSTANT VARCHAR2(2) := CHR(10);

    PROCEDURE P_REPORTE_SEMANAL IS
        v_prl NUMBER; v_dias NUMBER; v_meses NUMBER;
        v_msg CLOB; v_n1 NUMBER := 0; v_n2 NUMBER := 0;
    BEGIN
        v_prl   := PKG_PROCESOS.F_INICIAR('PKG_MERCADEO.P_REPORTE_SEMANAL');
        v_dias  := PKG_PARAMETROS.F_NUMERO('DIAS_POR_VENCER', 7);
        v_meses := PKG_PARAMETROS.F_NUMERO('MESES_ANTIGUEDAD_BODEGA', 6);

        v_msg := 'REPORTE SEMANAL DE MERCADEO - ' || TO_CHAR(SYSDATE, 'DD/MM/YYYY') || CRLF || CRLF
              || '== SECCION 1: PRODUCTOS POR VENCERSE (proximos ' || v_dias || ' dias) ==' || CRLF;
        FOR r IN (SELECT p.PRD_CODIGO, p.PRD_NOMBRE, l.LOT_NUMERO, l.LOT_FECHA_VENCIMIENTO, sl.STOCK_TOTAL
                    FROM LOTE l JOIN PRODUCTO p ON p.PRD_ID = l.PRD_ID JOIN VW_STOCK_LOTE sl ON sl.LOT_ID = l.LOT_ID
                   WHERE l.LOT_FECHA_VENCIMIENTO BETWEEN TRUNC(SYSDATE) AND TRUNC(SYSDATE) + v_dias
                     AND sl.STOCK_TOTAL > 0 ORDER BY l.LOT_FECHA_VENCIMIENTO) LOOP
            v_n1 := v_n1 + 1;
            v_msg := v_msg || ' - ' || r.PRD_CODIGO || ' ' || r.PRD_NOMBRE || ' | Lote ' || r.LOT_NUMERO
                  || ' | Vence ' || TO_CHAR(r.LOT_FECHA_VENCIMIENTO, 'DD/MM/YYYY') || ' | Existencia ' || r.STOCK_TOTAL || CRLF;
        END LOOP;
        IF v_n1 = 0 THEN v_msg := v_msg || ' (ninguno)' || CRLF; END IF;

        v_msg := v_msg || CRLF || '== SECCION 2: PRODUCTOS CON MAS DE ' || v_meses || ' MESES EN BODEGA ==' || CRLF;
        FOR r IN (SELECT p.PRD_CODIGO, p.PRD_NOMBRE, l.LOT_NUMERO, l.LOT_FECHA_INGRESO, sl.STOCK_TOTAL
                    FROM LOTE l JOIN PRODUCTO p ON p.PRD_ID = l.PRD_ID JOIN VW_STOCK_LOTE sl ON sl.LOT_ID = l.LOT_ID
                   WHERE l.LOT_FECHA_INGRESO <= ADD_MONTHS(TRUNC(SYSDATE), -v_meses)
                     AND sl.STOCK_TOTAL > 0 ORDER BY l.LOT_FECHA_INGRESO) LOOP
            v_n2 := v_n2 + 1;
            v_msg := v_msg || ' - ' || r.PRD_CODIGO || ' ' || r.PRD_NOMBRE || ' | Lote ' || r.LOT_NUMERO
                  || ' | Ingreso ' || TO_CHAR(r.LOT_FECHA_INGRESO, 'DD/MM/YYYY') || ' | Existencia ' || r.STOCK_TOTAL || CRLF;
        END LOOP;
        IF v_n2 = 0 THEN v_msg := v_msg || ' (ninguno)' || CRLF; END IF;

        PKG_NOTIF_NEGOCIO.P_ENVIAR('MERCADEO', 'COORDINADOR', 'Reporte semanal de mercadeo', v_msg);
        PKG_PROCESOS.P_FINALIZAR(v_prl, 'OK', 'Por vencer: ' || v_n1 || ' | Antiguos: ' || v_n2);
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_MERCADEO', 'P_REPORTE_SEMANAL', SQLCODE, SQLERRM);
            IF v_prl IS NOT NULL THEN PKG_PROCESOS.P_FINALIZAR(v_prl, 'ERROR', SQLERRM); END IF;
            RAISE;
    END P_REPORTE_SEMANAL;

    -- Lista de productos vencidos con existencia + total; marca los lotes como VENCIDO
    PROCEDURE P_NOTIFICAR_VENCIDOS IS
        v_prl NUMBER; v_msg CLOB; v_n NUMBER := 0; v_unid NUMBER := 0; v_valor NUMBER := 0;
    BEGIN
        SAVEPOINT sp_vencidos;
        v_prl := PKG_PROCESOS.F_INICIAR('PKG_MERCADEO.P_NOTIFICAR_VENCIDOS');
        v_msg := 'PRODUCTOS VENCIDOS AL ' || TO_CHAR(SYSDATE, 'DD/MM/YYYY') || CRLF || CRLF;
        FOR r IN (SELECT l.LOT_ID, p.PRD_CODIGO, p.PRD_NOMBRE, l.LOT_NUMERO, l.LOT_FECHA_VENCIMIENTO,
                         l.LOT_COSTO_UNITARIO, sl.STOCK_TOTAL
                    FROM LOTE l JOIN PRODUCTO p ON p.PRD_ID = l.PRD_ID JOIN VW_STOCK_LOTE sl ON sl.LOT_ID = l.LOT_ID
                   WHERE l.LOT_FECHA_VENCIMIENTO < TRUNC(SYSDATE) AND sl.STOCK_TOTAL > 0
                   ORDER BY l.LOT_FECHA_VENCIMIENTO) LOOP
            v_n := v_n + 1;
            v_unid  := v_unid + r.STOCK_TOTAL;
            v_valor := v_valor + r.STOCK_TOTAL * r.LOT_COSTO_UNITARIO;
            v_msg := v_msg || ' - ' || r.PRD_CODIGO || ' ' || r.PRD_NOMBRE || ' | Lote ' || r.LOT_NUMERO
                  || ' | Vencio ' || TO_CHAR(r.LOT_FECHA_VENCIMIENTO, 'DD/MM/YYYY') || ' | Existencia ' || r.STOCK_TOTAL
                  || ' | Costo ' || PKG_UTIL.F_MONTO(r.STOCK_TOTAL * r.LOT_COSTO_UNITARIO) || CRLF;
        END LOOP;

        IF v_n > 0 THEN
            v_msg := v_msg || CRLF || 'TOTAL: ' || v_n || ' lotes, ' || v_unid || ' unidades, costo ' || PKG_UTIL.F_MONTO(v_valor) || CRLF
                  || 'El coordinador debe definir que hacer con estos productos.';
            UPDATE LOTE SET LOT_ESTADO = 'VENCIDO'
             WHERE LOT_FECHA_VENCIMIENTO < TRUNC(SYSDATE) AND LOT_ESTADO = 'ACTIVO';
            COMMIT;
            PKG_NOTIF_NEGOCIO.P_ENVIAR('VENCIDOS', 'COORDINADOR', 'Productos vencidos (' || v_n || ' lotes)', v_msg);
        END IF;
        PKG_PROCESOS.P_FINALIZAR(v_prl, 'OK', 'Lotes vencidos con existencia: ' || v_n);
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN ROLLBACK TO sp_vencidos; EXCEPTION WHEN OTHERS THEN NULL; END;   -- si ya hubo COMMIT el savepoint no existe (ORA-01086); no se oculta el error original
            PKG_ERRORES.P_REGISTRAR('PKG_MERCADEO', 'P_NOTIFICAR_VENCIDOS', SQLCODE, SQLERRM);
            IF v_prl IS NOT NULL THEN PKG_PROCESOS.P_FINALIZAR(v_prl, 'ERROR', SQLERRM); END IF;
            RAISE;
    END P_NOTIFICAR_VENCIDOS;
END PKG_MERCADEO;
/

/* ============================================================================
   PKG_PREMIOS  -  mejores clientes (top N, orden de compra, cada N meses)
   El job corre a diario; el procedimiento se auto-controla con PROCESO_LOG para
   ejecutarse solo cada FRECUENCIA_PREMIOS_MESES (p_forzar = 'S' para la defensa).
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_PREMIOS AS
    PROCEDURE P_PREMIAR_MEJORES_CLIENTES (p_forzar IN VARCHAR2 DEFAULT 'N');
END PKG_PREMIOS;
/
CREATE OR REPLACE PACKAGE BODY PKG_PREMIOS AS
    CRLF CONSTANT VARCHAR2(2) := CHR(10);
    c_proc CONSTANT VARCHAR2(60) := 'PKG_PREMIOS.P_PREMIAR_MEJORES_CLIENTES';

    PROCEDURE P_PREMIAR_MEJORES_CLIENTES (p_forzar IN VARCHAR2 DEFAULT 'N') IS
        v_prl NUMBER; v_top NUMBER; v_monto NUMBER; v_meses NUMBER;
        v_ult DATE; v_ini DATE; v_fin DATE; v_msg CLOB; v_n NUMBER := 0;
    BEGIN
        SAVEPOINT sp_premios;
        v_top   := PKG_PARAMETROS.F_NUMERO('TOP_CLIENTES_PREMIADOS', 10);
        v_monto := PKG_PARAMETROS.F_NUMERO('MONTO_ORDEN_PREMIO', 100000);
        v_meses := PKG_PARAMETROS.F_NUMERO('FRECUENCIA_PREMIOS_MESES', 6);
        v_ult   := PKG_PROCESOS.F_ULTIMA_EJECUCION_OK(c_proc);

        IF p_forzar <> 'S' AND v_ult IS NOT NULL AND ADD_MONTHS(v_ult, v_meses) > SYSDATE THEN
            RETURN;                                -- aun no toca (frecuencia parametrizada)
        END IF;

        v_prl := PKG_PROCESOS.F_INICIAR(c_proc);
        v_fin := TRUNC(SYSDATE);
        v_ini := ADD_MONTHS(v_fin, -v_meses);

        v_msg := 'CLIENTES PREMIADOS - periodo ' || TO_CHAR(v_ini, 'DD/MM/YYYY') || ' al ' || TO_CHAR(v_fin, 'DD/MM/YYYY') || CRLF
              || 'Orden de compra por cliente: ' || PKG_UTIL.F_MONTO(v_monto) || CRLF || CRLF;
        FOR r IN (SELECT CLI_ID, NOMBRE, TOTAL, POS FROM (
                    SELECT f.CLI_ID, c.CLI_NOMBRE || ' ' || NVL(c.CLI_APELLIDO1, '') AS NOMBRE,
                           SUM(f.FAC_TOTAL) AS TOTAL,
                           ROW_NUMBER() OVER (ORDER BY SUM(f.FAC_TOTAL) DESC) AS POS
                      FROM FACTURA f JOIN CLIENTE c ON c.CLI_ID = f.CLI_ID
                     WHERE f.FAC_ESTADO IN ('PENDIENTE', 'CANCELADA')
                       AND f.FAC_FECHA >= v_ini AND f.FAC_FECHA < v_fin + 1
                       AND c.CLI_ES_DEFECTO = 'N' AND c.CLI_ESTADO = 'A'
                     GROUP BY f.CLI_ID, c.CLI_NOMBRE, c.CLI_APELLIDO1)
                   WHERE POS <= v_top ORDER BY POS) LOOP
            MERGE INTO CLIENTE_PREMIADO t
            USING (SELECT r.CLI_ID CLI_ID FROM DUAL) s ON (t.CLI_ID = s.CLI_ID AND t.CPR_PERIODO_FIN = v_fin)
             WHEN NOT MATCHED THEN INSERT (CLI_ID, CPR_PERIODO_INI, CPR_PERIODO_FIN, CPR_POSICION,
                                           CPR_TOTAL_COMPRADO, CPR_MONTO_ORDEN, CPR_ESTADO)
                  VALUES (r.CLI_ID, v_ini, v_fin, r.POS, r.TOTAL, v_monto, 'GENERADA');
            v_n := v_n + 1;
            v_msg := v_msg || r.POS || '. ' || r.NOMBRE || ' - comprado ' || PKG_UTIL.F_MONTO(r.TOTAL) || CRLF;
        END LOOP;
        COMMIT;

        IF v_n > 0 THEN
            PKG_NOTIF_NEGOCIO.P_ENVIAR('PREMIADOS', 'COORDINADOR', 'Clientes premiados del periodo', v_msg);
        END IF;
        PKG_PROCESOS.P_FINALIZAR(v_prl, 'OK', 'Clientes premiados: ' || v_n);
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN ROLLBACK TO sp_premios; EXCEPTION WHEN OTHERS THEN NULL; END;   -- si ya hubo COMMIT el savepoint no existe (ORA-01086); no se oculta el error original
            PKG_ERRORES.P_REGISTRAR('PKG_PREMIOS', 'P_PREMIAR_MEJORES_CLIENTES', SQLCODE, SQLERRM);
            IF v_prl IS NOT NULL THEN PKG_PROCESOS.P_FINALIZAR(v_prl, 'ERROR', SQLERRM); END IF;
            RAISE;
    END P_PREMIAR_MEJORES_CLIENTES;
END PKG_PREMIOS;
/

/* ============================================================================
   PKG_CIERRE  -  cierre diario (cabecera por fecha + detalle por cajero)
   Cantidad vendida = unidades facturadas (facturas no anuladas del dia);
   devoluciones = notas de credito aplicadas del dia; total neto = vendido - devoluciones.
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_CIERRE AS
    PROCEDURE P_CIERRE_DIARIO (p_fecha IN DATE DEFAULT TRUNC(SYSDATE));
END PKG_CIERRE;
/
CREATE OR REPLACE PACKAGE BODY PKG_CIERRE AS
    CRLF CONSTANT VARCHAR2(2) := CHR(10);

    PROCEDURE P_CIERRE_DIARIO (p_fecha IN DATE DEFAULT TRUNC(SYSDATE)) IS
        v_prl NUMBER; v_dia DATE := TRUNC(p_fecha); v_cie CIERRE_DIARIO.CIE_ID%TYPE;
        v_fact NUMBER; v_msg CLOB;
        v_cv NUMBER; v_cd NUMBER; v_tv NUMBER; v_td NUMBER;
    BEGIN
        SAVEPOINT sp_cierre;
        v_prl := PKG_PROCESOS.F_INICIAR('PKG_CIERRE.P_CIERRE_DIARIO');

        DELETE FROM CIERRE_DIARIO WHERE CIE_FECHA = v_dia;       -- recalculable (cascada al detalle)
        v_cie := SEQ_CIERRE_DIARIO.NEXTVAL;

        SELECT COUNT(*) INTO v_fact FROM FACTURA
         WHERE FAC_FECHA >= v_dia AND FAC_FECHA < v_dia + 1 AND FAC_ESTADO <> 'ANULADA';

        INSERT INTO CIERRE_DIARIO (CIE_ID, CIE_FECHA, CIE_CANT_FACTURAS, CIE_ESTADO) VALUES (v_cie, v_dia, v_fact, 'CERRADO');

        INSERT INTO CIERRE_DIARIO_DETALLE (CIE_ID, USR_ID, CID_CANT_VENDIDA, CID_CANT_DEVUELTA,
                                           CID_TOTAL_VENDIDO, CID_TOTAL_DEVOLUCIONES)
        SELECT v_cie, NVL(v.USR_ID, d.USR_ID), NVL(v.CANT, 0), NVL(d.CANT, 0), NVL(v.TOT, 0), NVL(d.TOT, 0)
          FROM (SELECT f.USR_ID, SUM(x.CANT) CANT, SUM(f.FAC_TOTAL) TOT
                  FROM FACTURA f
                  JOIN (SELECT FAC_ID, SUM(FCD_CANTIDAD) CANT FROM FAC_DETALLE GROUP BY FAC_ID) x ON x.FAC_ID = f.FAC_ID
                 WHERE f.FAC_FECHA >= v_dia AND f.FAC_FECHA < v_dia + 1 AND f.FAC_ESTADO <> 'ANULADA'
                 GROUP BY f.USR_ID) v
          FULL OUTER JOIN
               (SELECT n.USR_ID, SUM(nd.CANT) CANT, SUM(n.NTC_MONTO) TOT
                  FROM NOTA_CREDITO n
                  JOIN (SELECT NTC_ID, SUM(NTD_CANTIDAD) CANT FROM NTC_DETALLE GROUP BY NTC_ID) nd ON nd.NTC_ID = n.NTC_ID
                 WHERE n.NTC_FECHA >= v_dia AND n.NTC_FECHA < v_dia + 1 AND n.NTC_ESTADO = 'APLICADA'
                 GROUP BY n.USR_ID) d
            ON d.USR_ID = v.USR_ID;

        SELECT NVL(SUM(CID_CANT_VENDIDA), 0), NVL(SUM(CID_CANT_DEVUELTA), 0),
               NVL(SUM(CID_TOTAL_VENDIDO), 0), NVL(SUM(CID_TOTAL_DEVOLUCIONES), 0)
          INTO v_cv, v_cd, v_tv, v_td FROM CIERRE_DIARIO_DETALLE WHERE CIE_ID = v_cie;
        UPDATE CIERRE_DIARIO
           SET CIE_CANT_VENDIDA = v_cv, CIE_CANT_DEVUELTA = v_cd, CIE_TOTAL_VENDIDO = v_tv,
               CIE_TOTAL_DEVOLUCIONES = v_td, CIE_TOTAL_NETO = v_tv - v_td, CIE_FECHA_GENERACION = SYSDATE
         WHERE CIE_ID = v_cie;
        COMMIT;

        v_msg := 'CIERRE DIARIO DEL ' || TO_CHAR(v_dia, 'DD/MM/YYYY') || CRLF || CRLF
              || 'Facturas emitidas: ' || v_fact || CRLF
              || 'Cantidad vendida: ' || v_cv || CRLF
              || 'Cantidad devuelta: ' || v_cd || CRLF
              || 'Total vendido: ' || PKG_UTIL.F_MONTO(v_tv) || CRLF
              || 'Total devoluciones: ' || PKG_UTIL.F_MONTO(v_td) || CRLF
              || 'TOTAL NETO: ' || PKG_UTIL.F_MONTO(v_tv - v_td) || CRLF || CRLF || 'DETALLE POR CAJERO' || CRLF;
        FOR r IN (SELECT u.USR_NOMBRE, d.CID_CANT_VENDIDA, d.CID_CANT_DEVUELTA, d.CID_TOTAL_VENDIDO, d.CID_TOTAL_DEVOLUCIONES
                    FROM CIERRE_DIARIO_DETALLE d JOIN USUARIO u ON u.USR_ID = d.USR_ID
                   WHERE d.CIE_ID = v_cie ORDER BY u.USR_NOMBRE) LOOP
            v_msg := v_msg || ' - ' || r.USR_NOMBRE || ': vendido ' || r.CID_CANT_VENDIDA || ' (' || PKG_UTIL.F_MONTO(r.CID_TOTAL_VENDIDO)
                  || '), devuelto ' || r.CID_CANT_DEVUELTA || ' (' || PKG_UTIL.F_MONTO(r.CID_TOTAL_DEVOLUCIONES) || ')' || CRLF;
        END LOOP;
        PKG_NOTIF_NEGOCIO.P_ENVIAR('CIERRE_DIARIO', 'GERENTE,COORDINADOR',
                                   'Cierre diario ' || TO_CHAR(v_dia, 'DD/MM/YYYY'), v_msg);
        PKG_PROCESOS.P_FINALIZAR(v_prl, 'OK', 'Cierre ' || TO_CHAR(v_dia, 'DD/MM/YYYY') || ' neto ' || (v_tv - v_td));
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN ROLLBACK TO sp_cierre; EXCEPTION WHEN OTHERS THEN NULL; END;   -- si ya hubo COMMIT el savepoint no existe (ORA-01086); no se oculta el error original
            PKG_ERRORES.P_REGISTRAR('PKG_CIERRE', 'P_CIERRE_DIARIO', SQLCODE, SQLERRM, TO_CHAR(p_fecha, 'YYYY-MM-DD'));
            IF v_prl IS NOT NULL THEN PKG_PROCESOS.P_FINALIZAR(v_prl, 'ERROR', SQLERRM); END IF;
            RAISE;
    END P_CIERRE_DIARIO;
END PKG_CIERRE;
/

/* ============================================================================
   PKG_NOTIFICACIONES  -  alertas de credito y morosidad
   ============================================================================ */
CREATE OR REPLACE PACKAGE PKG_NOTIFICACIONES AS
    FUNCTION  F_EMAIL_CLIENTE (p_cli_id IN NUMBER) RETURN VARCHAR2;
    PROCEDURE P_CLIENTES_LIMITE;          -- a cada cliente con >= 85% de su limite (CxC)
    PROCEDURE P_COORDINADOR_LIMITES;      -- al coordinador: clientes (CxC) y proveedores (CxP) con >= 85%
    PROCEDURE P_GERENTE_PROVEEDORES;      -- al gerente: UNA notificacion con todos los proveedores >= 70%
    PROCEDURE P_MOROSOS;                  -- al gerente y coordinador: saldo pendiente y ultimo pago > 1 mes
    PROCEDURE P_EJECUTAR_TODAS;
END PKG_NOTIFICACIONES;
/
CREATE OR REPLACE PACKAGE BODY PKG_NOTIFICACIONES AS
    CRLF CONSTANT VARCHAR2(2) := CHR(10);

    FUNCTION F_EMAIL_CLIENTE (p_cli_id IN NUMBER) RETURN VARCHAR2 IS
        v_mail CLIENTE_CONTACTO.CCO_VALOR%TYPE;
    BEGIN
        SELECT CCO_VALOR INTO v_mail FROM CLIENTE_CONTACTO
         WHERE CLI_ID = p_cli_id AND CCO_TIPO = 'EMAIL'
         ORDER BY CASE CCO_PRINCIPAL WHEN 'S' THEN 0 ELSE 1 END, CCO_ID
         FETCH FIRST 1 ROW ONLY;
        RETURN v_mail;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RETURN NULL;
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_NOTIFICACIONES', 'F_EMAIL_CLIENTE', SQLCODE, SQLERRM, 'cli=' || p_cli_id);
            RAISE;
    END F_EMAIL_CLIENTE;

    PROCEDURE P_CLIENTES_LIMITE IS
        v_prl NUMBER; v_pct NUMBER; v_n NUMBER := 0; v_msg CLOB;
    BEGIN
        v_prl := PKG_PROCESOS.F_INICIAR('PKG_NOTIFICACIONES.P_CLIENTES_LIMITE');
        v_pct := PKG_PARAMETROS.F_NUMERO('PCT_ALERTA_CLIENTE', 85);
        FOR r IN (SELECT c.CLI_ID, c.CLI_NOMBRE || ' ' || NVL(c.CLI_APELLIDO1, '') AS NOMBRE,
                         c.CLI_SALDO_ACTUAL SALDO, c.CLI_LIMITE_CREDITO LIM,
                         ROUND(c.CLI_SALDO_ACTUAL / c.CLI_LIMITE_CREDITO * 100, 1) PCT
                    FROM CLIENTE c
                   WHERE c.CLI_ESTADO = 'A' AND c.CLI_LIMITE_CREDITO > 0
                     AND c.CLI_SALDO_ACTUAL >= c.CLI_LIMITE_CREDITO * v_pct / 100) LOOP
            v_msg := 'Estimado(a) ' || r.NOMBRE || ',' || CRLF || CRLF
                  || 'Le informamos que su saldo en cuentas por cobrar es de ' || PKG_UTIL.F_MONTO(r.SALDO)
                  || ', que corresponde al ' || r.PCT || '% de su limite de credito de ' || PKG_UTIL.F_MONTO(r.LIM) || '.' || CRLF
                  || 'Le agradecemos realizar un abono para mantener disponible su credito.';
            PKG_NOTIF_NEGOCIO.P_ENVIAR('LIMITE_CLIENTE', 'CLIENTE', 'Aviso: su credito esta al ' || r.PCT || '%', v_msg,
                                       F_EMAIL_CLIENTE(r.CLI_ID));
            v_n := v_n + 1;
        END LOOP;
        PKG_PROCESOS.P_FINALIZAR(v_prl, 'OK', 'Clientes notificados: ' || v_n);
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_NOTIFICACIONES', 'P_CLIENTES_LIMITE', SQLCODE, SQLERRM);
            IF v_prl IS NOT NULL THEN PKG_PROCESOS.P_FINALIZAR(v_prl, 'ERROR', SQLERRM); END IF;
            RAISE;
    END P_CLIENTES_LIMITE;

    PROCEDURE P_COORDINADOR_LIMITES IS
        v_prl NUMBER; v_pct NUMBER; v_n1 NUMBER := 0; v_n2 NUMBER := 0; v_msg CLOB;
    BEGIN
        v_prl := PKG_PROCESOS.F_INICIAR('PKG_NOTIFICACIONES.P_COORDINADOR_LIMITES');
        v_pct := PKG_PARAMETROS.F_NUMERO('PCT_ALERTA_COORD', 85);
        v_msg := 'ALERTA DE LIMITES (>= ' || v_pct || '% del saldo permitido)' || CRLF || CRLF || '== CLIENTES (cuentas por cobrar) ==' || CRLF;
        FOR r IN (SELECT c.CLI_NOMBRE || ' ' || NVL(c.CLI_APELLIDO1, '') NOMBRE, c.CLI_SALDO_ACTUAL SALDO, c.CLI_LIMITE_CREDITO LIM,
                         ROUND(c.CLI_SALDO_ACTUAL / c.CLI_LIMITE_CREDITO * 100, 1) PCT
                    FROM CLIENTE c WHERE c.CLI_LIMITE_CREDITO > 0 AND c.CLI_SALDO_ACTUAL >= c.CLI_LIMITE_CREDITO * v_pct / 100
                   ORDER BY 4 DESC) LOOP
            v_n1 := v_n1 + 1;
            v_msg := v_msg || ' - ' || r.NOMBRE || ': ' || PKG_UTIL.F_MONTO(r.SALDO) || ' de ' || PKG_UTIL.F_MONTO(r.LIM) || ' (' || r.PCT || '%)' || CRLF;
        END LOOP;
        IF v_n1 = 0 THEN v_msg := v_msg || ' (ninguno)' || CRLF; END IF;
        v_msg := v_msg || CRLF || '== PROVEEDORES (cuentas por pagar) ==' || CRLF;
        FOR r IN (SELECT p.PRV_RAZON_SOCIAL NOMBRE, p.PRV_SALDO_ACTUAL SALDO, p.PRV_LIMITE_CREDITO LIM,
                         ROUND(p.PRV_SALDO_ACTUAL / p.PRV_LIMITE_CREDITO * 100, 1) PCT
                    FROM PROVEEDOR p WHERE p.PRV_LIMITE_CREDITO > 0 AND p.PRV_SALDO_ACTUAL >= p.PRV_LIMITE_CREDITO * v_pct / 100
                   ORDER BY 4 DESC) LOOP
            v_n2 := v_n2 + 1;
            v_msg := v_msg || ' - ' || r.NOMBRE || ': ' || PKG_UTIL.F_MONTO(r.SALDO) || ' de ' || PKG_UTIL.F_MONTO(r.LIM) || ' (' || r.PCT || '%)' || CRLF;
        END LOOP;
        IF v_n2 = 0 THEN v_msg := v_msg || ' (ninguno)' || CRLF; END IF;
        IF v_n1 + v_n2 > 0 THEN
            PKG_NOTIF_NEGOCIO.P_ENVIAR('COORD_LIMITES', 'COORDINADOR', 'Clientes y proveedores cerca del limite', v_msg);
        END IF;
        PKG_PROCESOS.P_FINALIZAR(v_prl, 'OK', 'Clientes: ' || v_n1 || ' | Proveedores: ' || v_n2);
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_NOTIFICACIONES', 'P_COORDINADOR_LIMITES', SQLCODE, SQLERRM);
            IF v_prl IS NOT NULL THEN PKG_PROCESOS.P_FINALIZAR(v_prl, 'ERROR', SQLERRM); END IF;
            RAISE;
    END P_COORDINADOR_LIMITES;

    PROCEDURE P_GERENTE_PROVEEDORES IS
        v_prl NUMBER; v_pct NUMBER; v_n NUMBER := 0; v_msg CLOB;
    BEGIN
        v_prl := PKG_PROCESOS.F_INICIAR('PKG_NOTIFICACIONES.P_GERENTE_PROVEEDORES');
        v_pct := PKG_PARAMETROS.F_NUMERO('PCT_ALERTA_PROVEEDOR', 70);
        v_msg := 'PROVEEDORES CON MAS DEL ' || v_pct || '% DEL LIMITE DE CREDITO USADO' || CRLF || CRLF;
        FOR r IN (SELECT p.PRV_RAZON_SOCIAL NOMBRE, p.PRV_SALDO_ACTUAL SALDO, p.PRV_LIMITE_CREDITO LIM,
                         ROUND(p.PRV_SALDO_ACTUAL / p.PRV_LIMITE_CREDITO * 100, 1) PCT
                    FROM PROVEEDOR p WHERE p.PRV_ESTADO = 'A' AND p.PRV_LIMITE_CREDITO > 0
                     AND p.PRV_SALDO_ACTUAL >= p.PRV_LIMITE_CREDITO * v_pct / 100 ORDER BY 4 DESC) LOOP
            v_n := v_n + 1;
            v_msg := v_msg || ' - ' || r.NOMBRE || ': debe ' || PKG_UTIL.F_MONTO(r.SALDO) || ' de ' || PKG_UTIL.F_MONTO(r.LIM) || ' (' || r.PCT || '%)' || CRLF;
        END LOOP;
        IF v_n > 0 THEN                      -- una sola notificacion con todos los proveedores
            PKG_NOTIF_NEGOCIO.P_ENVIAR('LIMITE_PROVEEDOR', 'GERENTE', 'Proveedores cerca del limite de credito (' || v_n || ')', v_msg);
        END IF;
        PKG_PROCESOS.P_FINALIZAR(v_prl, 'OK', 'Proveedores en alerta: ' || v_n);
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_NOTIFICACIONES', 'P_GERENTE_PROVEEDORES', SQLCODE, SQLERRM);
            IF v_prl IS NOT NULL THEN PKG_PROCESOS.P_FINALIZAR(v_prl, 'ERROR', SQLERRM); END IF;
            RAISE;
    END P_GERENTE_PROVEEDORES;

    PROCEDURE P_MOROSOS IS
        v_prl NUMBER; v_dias NUMBER; v_n NUMBER := 0; v_msg CLOB;
    BEGIN
        v_prl  := PKG_PROCESOS.F_INICIAR('PKG_NOTIFICACIONES.P_MOROSOS');
        v_dias := PKG_PARAMETROS.F_NUMERO('DIAS_MOROSIDAD', 30);
        v_msg  := 'CLIENTES MOROSOS (saldo pendiente y ultimo pago hace mas de ' || v_dias || ' dias)' || CRLF || CRLF;
        FOR r IN (SELECT NOMBRE, SALDO, REF FROM (
                    SELECT c.CLI_NOMBRE || ' ' || NVL(c.CLI_APELLIDO1, '') AS NOMBRE, c.CLI_SALDO_ACTUAL AS SALDO,
                           NVL((SELECT MAX(a.ABC_FECHA) FROM CXC_ABONO a JOIN CUENTA_POR_COBRAR x ON x.CXC_ID = a.CXC_ID
                                 WHERE x.CLI_ID = c.CLI_ID),
                               (SELECT MIN(f.FAC_FECHA) FROM CUENTA_POR_COBRAR x JOIN FACTURA f ON f.FAC_ID = x.FAC_ID
                                 WHERE x.CLI_ID = c.CLI_ID AND x.CXC_ESTADO IN ('PENDIENTE', 'PARCIAL'))) AS REF
                      FROM CLIENTE c WHERE c.CLI_SALDO_ACTUAL > 0)
                   WHERE REF < SYSDATE - v_dias ORDER BY REF) LOOP
            v_n := v_n + 1;
            v_msg := v_msg || ' - ' || r.NOMBRE || ': saldo ' || PKG_UTIL.F_MONTO(r.SALDO) || ', ultimo pago (o factura mas antigua) '
                  || TO_CHAR(r.REF, 'DD/MM/YYYY') || CRLF;
        END LOOP;
        IF v_n > 0 THEN
            PKG_NOTIF_NEGOCIO.P_ENVIAR('MOROSOS', 'GERENTE,COORDINADOR', 'Clientes morosos (' || v_n || ')', v_msg);
        END IF;
        PKG_PROCESOS.P_FINALIZAR(v_prl, 'OK', 'Morosos: ' || v_n);
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_NOTIFICACIONES', 'P_MOROSOS', SQLCODE, SQLERRM);
            IF v_prl IS NOT NULL THEN PKG_PROCESOS.P_FINALIZAR(v_prl, 'ERROR', SQLERRM); END IF;
            RAISE;
    END P_MOROSOS;

    PROCEDURE P_EJECUTAR_TODAS IS
    BEGIN
        P_CLIENTES_LIMITE;
        P_COORDINADOR_LIMITES;
        P_GERENTE_PROVEEDORES;
        P_MOROSOS;
    EXCEPTION
        WHEN OTHERS THEN
            PKG_ERRORES.P_REGISTRAR('PKG_NOTIFICACIONES', 'P_EJECUTAR_TODAS', SQLCODE, SQLERRM);
            RAISE;
    END P_EJECUTAR_TODAS;
END PKG_NOTIFICACIONES;
/
SHOW ERRORS

/* ============================== FIN DEL SCRIPT ============================== */
