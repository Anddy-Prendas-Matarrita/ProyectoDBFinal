/* ============================================================================
   ENTREGABLE #2 - PARTE A - 09_pruebas_entrega1.sql
   Pruebas funcionales de la Entrega 1. Ejecutar bloque por bloque con
   SET SERVEROUTPUT ON y revisar los resultados esperados (comentarios).
   ============================================================================ */
ALTER SESSION SET CURRENT_SCHEMA = SUM_ADMIN;
SET SERVEROUTPUT ON

-- 1) Factura de CONTADO: baja el inventario de la sucursal 1 (lote 1) y queda CANCELADA
DECLARE
    v_lin PKG_FACTURACION.t_lineas_fac; v_fac NUMBER;
BEGIN
    v_lin(1).lot_id := 1; v_lin(1).cantidad := 2;
    PKG_FACTURACION.P_FACTURAR(2, 1, 2, 'CONTADO', v_lin, 1, NULL, v_fac);
    DBMS_OUTPUT.PUT_LINE('Factura contado creada: ' || v_fac);
END;
/
SELECT FAC_NUMERO, FAC_TIPO, FAC_ESTADO, FAC_TOTAL FROM FACTURA ORDER BY FAC_ID DESC FETCH FIRST 1 ROW ONLY;
SELECT BMI_TIPO, BMI_CANTIDAD, BMI_SALDO_ANT, BMI_SALDO_NUE, BMI_REFERENCIA FROM BIT_MOV_INVENTARIO ORDER BY BMI_ID DESC FETCH FIRST 1 ROW ONLY;

-- 2) Factura a CREDITO (cliente 5): estado PENDIENTE, nueva CXC y saldo del cliente aumentado
SELECT CLI_ID, CLI_SALDO_ACTUAL FROM CLIENTE WHERE CLI_ID = 5;     -- saldo ANTES
DECLARE
    v_lin PKG_FACTURACION.t_lineas_fac; v_fac NUMBER;
BEGIN
    v_lin(1).lot_id := 3; v_lin(1).cantidad := 3;
    PKG_FACTURACION.P_FACTURAR(5, 1, 2, 'CREDITO', v_lin, NULL, NULL, v_fac);
    DBMS_OUTPUT.PUT_LINE('Factura credito creada: ' || v_fac);
END;
/
SELECT CLI_ID, CLI_SALDO_ACTUAL FROM CLIENTE WHERE CLI_ID = 5;     -- saldo DESPUES (aumenta)
SELECT * FROM VW_CXC_PENDIENTES WHERE CLIENTE LIKE 'Cooperativa%';

-- 3) Abono total: la cuenta pasa a PAGADA y la factura de PENDIENTE a CANCELADA (automatico)
DECLARE
    v_cxc NUMBER; v_saldo NUMBER;
BEGIN
    SELECT CXC_ID, CXC_SALDO INTO v_cxc, v_saldo FROM CUENTA_POR_COBRAR
     WHERE FAC_ID = (SELECT MAX(FAC_ID) FROM FACTURA WHERE FAC_TIPO = 'CREDITO');
    PKG_CUENTAS.P_REGISTRAR_ABONO_CXC(v_cxc, 1, v_saldo, 'PRUEBA-PAGO-TOTAL');
END;
/
SELECT f.FAC_NUMERO, f.FAC_ESTADO, c.CXC_ESTADO, c.CXC_SALDO FROM FACTURA f
  JOIN CUENTA_POR_COBRAR c ON c.FAC_ID = f.FAC_ID ORDER BY f.FAC_ID DESC FETCH FIRST 1 ROW ONLY;

-- 4) Limite de credito: debe FALLAR con ORA-20102 y quedar en BIT_ERROR
DECLARE
    v_lin PKG_FACTURACION.t_lineas_fac; v_fac NUMBER;
BEGIN
    v_lin(1).lot_id := 5; v_lin(1).cantidad := 4;         -- silla ejecutiva x4
    PKG_FACTURACION.P_FACTURAR(2, 1, 2, 'CREDITO', v_lin, NULL, NULL, v_fac);  -- cliente 2: limite 500.000
EXCEPTION WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('ERROR ESPERADO: ' || SQLERRM);
END;
/
SELECT BER_MODULO, BER_OBJETO, BER_CODIGO, SUBSTR(BER_MENSAJE,1,120) MENSAJE FROM BIT_ERROR ORDER BY BER_ID DESC FETCH FIRST 3 ROWS ONLY;

-- 5) Cliente NO preferencial no puede dejar facturas pendientes (ORA-20101)
DECLARE
    v_lin PKG_FACTURACION.t_lineas_fac; v_fac NUMBER;
BEGIN
    v_lin(1).lot_id := 1; v_lin(1).cantidad := 1;
    PKG_FACTURACION.P_FACTURAR(3, 1, 2, 'CREDITO', v_lin, NULL, NULL, v_fac);
EXCEPTION WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('ERROR ESPERADO: ' || SQLERRM);
END;
/

-- 6) Anulacion de factura de contado: el stock regresa
DECLARE
    v_fac NUMBER;
BEGIN
    SELECT MIN(FAC_ID) INTO v_fac FROM FACTURA WHERE FAC_NUMERO = 'FE-000005';   -- contado, estado CANCELADA
    PKG_FACTURACION.P_ANULAR_FACTURA(v_fac, 'Prueba de anulacion');
END;
/
SELECT FAC_NUMERO, FAC_ESTADO FROM FACTURA WHERE FAC_NUMERO = 'FE-000005';

-- 7) Devolucion parcial de cliente: nota de credito + stock regresa
DECLARE
    v_dev PKG_FACTURACION.t_lineas_dev; v_ntc NUMBER;
BEGIN
    v_dev(1).fcd_id := 1; v_dev(1).cantidad := 1;      -- linea 1 de la factura FE-000001
    PKG_FACTURACION.P_DEVOLVER_CLIENTE(1, 2, 'Prueba de devolucion parcial', v_dev, v_ntc);
    DBMS_OUTPUT.PUT_LINE('Nota de credito: ' || v_ntc);
END;
/

-- 8) Compra a proveedor PENDIENTE con costo distinto: sube saldo del proveedor, entra a bodega central,
--    cambia el costo del producto 1 y queda en el historial de precios
SELECT PRV_ID, PRV_SALDO_ACTUAL FROM PROVEEDOR WHERE PRV_ID = 1;
DECLARE
    v_lin PKG_COMPRAS.t_lineas_compra; v_cxp NUMBER;
BEGIN
    v_lin(1).prd_id := 1; v_lin(1).lote_numero := NULL; v_lin(1).cantidad := 100;
    v_lin(1).costo := 2400; v_lin(1).fecha_venc := NULL;
    PKG_COMPRAS.P_REGISTRAR_COMPRA(1, 'FP-1-9001', 30, 'S', v_lin, v_cxp);
    DBMS_OUTPUT.PUT_LINE('CXP creada: ' || v_cxp);
END;
/
SELECT PRV_ID, PRV_SALDO_ACTUAL FROM PROVEEDOR WHERE PRV_ID = 1;                       -- aumento de 240.000
SELECT PRD_ID, PRD_PRECIO_COSTO FROM PRODUCTO WHERE PRD_ID = 1;                        -- 2400
SELECT PRD_ID, NEG_ID, HIS_COSTO, HIS_PRECIO_VENTA, HIS_FECHA_DESDE, HIS_FECHA_HASTA FROM HISTORICO_PRECIO
 WHERE PRD_ID = 1 ORDER BY HIS_ID;                                                      -- un vigente (HASTA nulo) por negocio
SELECT PRD_ID, NEG_ID, BCP_COSTO_ANT, BCP_COSTO_NUE, BCP_PRECIO_ANT, BCP_PRECIO_NUE FROM BIT_CAMBIO_PRECIO ORDER BY BCP_ID DESC FETCH FIRST 3 ROWS ONLY;

-- 9) Limite del proveedor: debe FALLAR (ORA-20111). Proveedor 5, limite 2.000.000
DECLARE
    v_lin PKG_COMPRAS.t_lineas_compra; v_cxp NUMBER;
BEGIN
    v_lin(1).prd_id := 5; v_lin(1).cantidad := 2000; v_lin(1).costo := 1550;
    PKG_COMPRAS.P_REGISTRAR_COMPRA(5, 'FP-5-9002', 30, 'S', v_lin, v_cxp);
EXCEPTION WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('ERROR ESPERADO: ' || SQLERRM);
END;
/

-- 10) Abono a proveedor y devolucion a proveedor aplicada a la cuenta
DECLARE
    v_cxp NUMBER;
BEGIN
    SELECT MAX(CXP_ID) INTO v_cxp FROM CUENTA_POR_PAGAR;
    PKG_CUENTAS.P_REGISTRAR_ABONO_CXP(v_cxp, 1, 40000, 'PRUEBA-ABONO');
END;
/

-- 11) Padron: un cliente nuevo NACIONAL toma sus datos del padron (cedula 111110001)
INSERT INTO CLIENTE (CLI_CEDULA, CLI_NOMBRE, CLI_TIPO_PERSONA) VALUES ('111110001', 'x', 'NACIONAL');
SELECT CLI_CEDULA, CLI_NOMBRE, CLI_APELLIDO1, CLI_APELLIDO2, CLI_SEXO, CLI_PAD_ID FROM CLIENTE WHERE CLI_CEDULA = '111110001';
ROLLBACK;
