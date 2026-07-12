/* ============================================================================
   FILE:        03_scd2_load_procedure.sql
   PROJECT:     P02 - Data Governance Architecture | TRANSTRACK
   FOLDER:      06-analytical-modeling
   PURPOSE:     Incremental load procedures (SCD2 for Dim_Cliente, upsert for
                Type-1 dimensions, point-in-time resolved loads for facts)
   AUTHOR:      cblancogt
   ============================================================================ */

USE TRANSTRACK;
GO

/* ============================================================================
   usp_Load_Dim_Cliente_SCD2
   ----------------------------------------------------------------------------
   Pattern: hash-diff comparison + MERGE. Rather than comparing every Type-2
   column individually (which forces a table scan because no index can be
   built on "any of these 5 columns changed"), we precompute a single
   HASHBYTES('MD5', ...) of the concatenated Type-2 attributes at read time
   and store it as hash_diff. Detecting a change becomes an equality check
   on one fixed-length column, which the source query can seek on and which
   keeps the comparison logic in one place instead of N places.

   DBA PRACTICE NOTE: run this procedure with SET STATISTICS XML ON once
   after the initial load to confirm the plan uses the nonclustered index
   IX_Dim_Cliente_Actual (WHERE es_version_actual = 1) for the "find current
   row" step, rather than scanning the whole SCD2 history table as it grows.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dw.usp_Load_Dim_Cliente_SCD2
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Staging: pull current state from the golden record, with a hash of
        -- the Type-2 attributes we track.
        ;WITH Source AS (
            SELECT
                mc.master_cliente_id,
                mc.client_hash_key,
                mc.nit_ventas,
                mc.nit_facturacion,
                mc.nombre,
                mc.email,
                mc.telefono,
                mc.ciudad,
                mc.categoria,
                mc.limite_credito,
                mc.dias_credito,
                CONVERT(CHAR(32), HASHBYTES('MD5',
                    CONCAT_WS('|',
                        ISNULL(mc.categoria, ''),
                        ISNULL(CAST(mc.limite_credito AS VARCHAR(20)), ''),
                        ISNULL(CAST(mc.dias_credito AS VARCHAR(10)), '')
                    )), 2) AS hash_diff
            FROM governance_control.MASTER_CLIENTE mc
            WHERE mc.estado_activo = 1
        )

        -- STEP 1: expire current rows whose Type-2 attributes changed.
        UPDATE d
        SET fecha_fin_vigencia = SYSUTCDATETIME(),
            es_version_actual  = 0
        FROM dw.Dim_Cliente d
        INNER JOIN Source s
            ON s.master_cliente_id = d.master_cliente_id
        WHERE d.es_version_actual = 1
          AND d.hash_diff <> s.hash_diff;

        -- STEP 2: insert a new current version for changed clients, carrying
        -- the version number forward. This is the row that gives the star
        -- schema its historical value (e.g. "client X was 'pequeño' before
        -- 2024-03-01 and 'corporativo' after").
        ;WITH Source AS (
            SELECT
                mc.master_cliente_id, mc.client_hash_key, mc.nit_ventas, mc.nit_facturacion,
                mc.nombre, mc.email, mc.telefono, mc.ciudad, mc.categoria,
                mc.limite_credito, mc.dias_credito,
                CONVERT(CHAR(32), HASHBYTES('MD5',
                    CONCAT_WS('|', ISNULL(mc.categoria, ''),
                        ISNULL(CAST(mc.limite_credito AS VARCHAR(20)), ''),
                        ISNULL(CAST(mc.dias_credito AS VARCHAR(10)), ''))), 2) AS hash_diff
            FROM governance_control.MASTER_CLIENTE mc
            WHERE mc.estado_activo = 1
        )
        INSERT INTO dw.Dim_Cliente
        (
            master_cliente_id, client_hash_key, nit_ventas, nit_facturacion, nombre,
            email, telefono, ciudad, categoria, limite_credito, dias_credito,
            fecha_inicio_vigencia, fecha_fin_vigencia, es_version_actual,
            numero_version, hash_diff
        )
        SELECT
            s.master_cliente_id, s.client_hash_key, s.nit_ventas, s.nit_facturacion, s.nombre,
            s.email, s.telefono, s.ciudad, s.categoria, s.limite_credito, s.dias_credito,
            SYSUTCDATETIME(), NULL, 1,
            ISNULL((SELECT MAX(d2.numero_version) FROM dw.Dim_Cliente d2
                    WHERE d2.master_cliente_id = s.master_cliente_id), 0) + 1,
            s.hash_diff
        FROM Source s
        WHERE NOT EXISTS (
            SELECT 1 FROM dw.Dim_Cliente d
            WHERE d.master_cliente_id = s.master_cliente_id
              AND d.es_version_actual = 1
              AND d.hash_diff = s.hash_diff
        );

        COMMIT TRANSACTION;

        SELECT 'dw.Dim_Cliente SCD2 load completed.' AS resultado, @@ROWCOUNT AS filas_afectadas;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ============================================================================
   usp_Load_Dim_Type1  - generic-pattern procedures for the Type-1 dimensions.
   Simple MERGE upsert: no history needed, so a plain MERGE keyed on the
   natural business key is sufficient and cheaper than the SCD2 pattern above.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dw.usp_Load_Dim_Conductor
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dw.Dim_Conductor AS tgt
    USING (
        SELECT master_conductor_id, conductor_hash_key, numero_licencia, codigo_empleado,
               id_operador, nombre_completo, telefono, email, categoria_licencia,
               fecha_vencimiento_lic, licencia_vigente, estado_activo, num_fuentes AS num_fuentes_origen
        FROM governance_control.MASTER_CONDUCTOR
    ) AS src
    ON tgt.master_conductor_id = src.master_conductor_id
    WHEN MATCHED THEN UPDATE SET
        numero_licencia = src.numero_licencia, codigo_empleado = src.codigo_empleado,
        id_operador = src.id_operador, nombre_completo = src.nombre_completo,
        telefono = src.telefono, email = src.email, categoria_licencia = src.categoria_licencia,
        fecha_vencimiento_lic = src.fecha_vencimiento_lic,
        licencia_vigente = CAST(src.licencia_vigente AS BIT),
        estado_activo = src.estado_activo, num_fuentes_origen = src.num_fuentes_origen,
        fecha_carga = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (master_conductor_id, conductor_hash_key, numero_licencia, codigo_empleado, id_operador,
         nombre_completo, telefono, email, categoria_licencia, fecha_vencimiento_lic,
         licencia_vigente, estado_activo, num_fuentes_origen)
    VALUES
        (src.master_conductor_id, src.conductor_hash_key, src.numero_licencia, src.codigo_empleado,
         src.id_operador, src.nombre_completo, src.telefono, src.email, src.categoria_licencia,
         src.fecha_vencimiento_lic, CAST(src.licencia_vigente AS BIT), src.estado_activo, src.num_fuentes_origen);
END;
GO

CREATE OR ALTER PROCEDURE dw.usp_Load_Dim_Vehiculo
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dw.Dim_Vehiculo AS tgt
    USING flota.VEHICULO AS src
        ON tgt.vehiculo_id = src.vehiculo_id
    WHEN MATCHED THEN UPDATE SET
        placa = src.placa, marca = src.marca, modelo = src.modelo, anio = src.anio,
        tipo_vehiculo = src.tipo_vehiculo, capacidad_ton = src.capacidad_ton,
        estado = src.estado, km_actuales = src.km_actuales, fecha_carga = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (vehiculo_id, placa, marca, modelo, anio, tipo_vehiculo, capacidad_ton, estado, fecha_adquisicion, km_actuales)
    VALUES
        (src.vehiculo_id, src.placa, src.marca, src.modelo, src.anio, src.tipo_vehiculo,
         src.capacidad_ton, src.estado, src.fecha_adquisicion, src.km_actuales);
END;
GO

CREATE OR ALTER PROCEDURE dw.usp_Load_Dim_Ruta
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dw.Dim_Ruta AS tgt
    USING operaciones.RUTA AS src
        ON tgt.ruta_id = src.ruta_id
    WHEN MATCHED THEN UPDATE SET
        codigo_ruta = src.codigo_ruta, ciudad_origen = src.ciudad_origen,
        ciudad_destino = src.ciudad_destino, distancia_km = src.distancia_km,
        tiempo_estimado_h = src.tiempo_estimado_h, tipo_via = src.tipo_via,
        activa = src.activa, fecha_carga = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (ruta_id, codigo_ruta, ciudad_origen, ciudad_destino, distancia_km, tiempo_estimado_h, tipo_via, activa)
    VALUES
        (src.ruta_id, src.codigo_ruta, src.ciudad_origen, src.ciudad_destino,
         src.distancia_km, src.tiempo_estimado_h, src.tipo_via, src.activa);
END;
GO

CREATE OR ALTER PROCEDURE dw.usp_Load_Dim_EstadoEntrega
AS
BEGIN
    SET NOCOUNT ON;
    -- estado_entrega is a small, low-cardinality domain (source: operaciones.ENTREGA.estado_entrega).
    -- Order/labels/final-flag are governed manually via REF_DATA_REGISTRY, so this only inserts
    -- codes that don't exist yet - it never overwrites the curated description/order.
    INSERT INTO dw.Dim_EstadoEntrega (codigo_estado, descripcion, es_estado_final, orden_presentacion)
    SELECT DISTINCT e.estado_entrega, e.estado_entrega, 0, 99
    FROM operaciones.ENTREGA e
    WHERE NOT EXISTS (
        SELECT 1 FROM dw.Dim_EstadoEntrega x WHERE x.codigo_estado = e.estado_entrega
    );
END;
GO

/* ============================================================================
   usp_Load_Fact_Pedido
   ============================================================================ */
CREATE OR ALTER PROCEDURE dw.usp_Load_Fact_Pedido
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dw.Fact_Pedido
    (
        pedido_id, numero_pedido, cliente_sk, ruta_sk, tiempo_pedido_sk, tiempo_requerido_sk,
        fecha_pedido_real, fecha_requerida_real, tipo_carga, estado_pedido,
        peso_kg, volumen_m3, valor_declarado
    )
    SELECT
        p.pedido_id, p.numero_pedido, dc.cliente_sk, dr.ruta_sk,
        CAST(FORMAT(p.fecha_pedido, 'yyyyMMdd') AS INT),
        CAST(FORMAT(p.fecha_requerida, 'yyyyMMdd') AS INT),
        CAST(p.fecha_pedido AS DATE), p.fecha_requerida,
        p.tipo_carga, p.estado, p.peso_kg, p.volumen_m3, p.valor_declarado
    FROM operaciones.PEDIDO p
    -- resolve the client via the crosswalk built in folder 05, not a direct join
    -- to ventas.CLIENTE, because ventas.CLIENTE.cliente_id is a fragmented source key
    INNER JOIN governance_control.CLIENTE_CROSSWALK cw
        ON cw.source_pk = p.cliente_id AND cw.source_modulo = 'ventas' AND cw.is_survivor = 1
    INNER JOIN dw.Dim_Cliente dc
        ON dc.master_cliente_id = cw.master_cliente_id AND dc.es_version_actual = 1
    INNER JOIN dw.Dim_Ruta dr
        ON dr.ruta_id = p.ruta_id
    WHERE NOT EXISTS (SELECT 1 FROM dw.Fact_Pedido fp WHERE fp.pedido_id = p.pedido_id);
END;
GO

/* ============================================================================
   usp_Load_Fact_Entrega
   ----------------------------------------------------------------------------
   This is the point-in-time join referenced in 02_star_schema_facts.sql.
   flota.ASIGNACION_VEHICULO can carry more than one row per pedido_id over
   time (reassignments); we take the assignment whose date range contains the
   delivery's fecha_salida, falling back to fecha_entrega_est when
   fecha_salida is NULL (source allows NULL on fecha_salida for cancelled runs).
   ============================================================================ */
CREATE OR ALTER PROCEDURE dw.usp_Load_Fact_Entrega
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH EntregaConReferencia AS (
        SELECT
            e.*,
            p.cliente_id AS ventas_cliente_id,
            p.ruta_id,
            COALESCE(e.fecha_salida, e.fecha_entrega_est) AS fecha_referencia
        FROM operaciones.ENTREGA e
        INNER JOIN operaciones.PEDIDO p ON p.pedido_id = e.pedido_id
    ),
    AsignacionResuelta AS (
        SELECT
            ecr.entrega_id,
            av.conductor_id,
            av.vehiculo_id,
            ROW_NUMBER() OVER (
                PARTITION BY ecr.entrega_id
                ORDER BY av.fecha_inicio DESC
            ) AS rn
        FROM EntregaConReferencia ecr
        LEFT JOIN flota.ASIGNACION_VEHICULO av
            ON av.pedido_id = ecr.pedido_id
           AND av.fecha_inicio <= ecr.fecha_referencia
           AND (av.fecha_fin IS NULL OR av.fecha_fin >= ecr.fecha_referencia)
    )
    INSERT INTO dw.Fact_Entrega
    (
        entrega_id, pedido_id, cliente_sk, conductor_sk, vehiculo_sk, ruta_sk, estado_entrega_sk,
        tiempo_salida_sk, tiempo_entrega_est_sk, tiempo_entrega_real_sk,
        asignacion_resuelta, tiempo_demora_min, cumplio_sla_flag
    )
    SELECT
        ecr.entrega_id, ecr.pedido_id, dc.cliente_sk, dcond.conductor_sk, dveh.vehiculo_sk,
        dr.ruta_sk, dee.estado_entrega_sk,
        CASE WHEN ecr.fecha_salida IS NULL THEN NULL ELSE CAST(FORMAT(ecr.fecha_salida, 'yyyyMMdd') AS INT) END,
        CAST(FORMAT(ecr.fecha_entrega_est, 'yyyyMMdd') AS INT),
        CASE WHEN ecr.fecha_entrega_real IS NULL THEN NULL ELSE CAST(FORMAT(ecr.fecha_entrega_real, 'yyyyMMdd') AS INT) END,
        CASE WHEN ar.conductor_id IS NOT NULL THEN 1 ELSE 0 END,
        ecr.tiempo_demora_min,
        CASE WHEN ecr.fecha_entrega_real IS NOT NULL
                  AND ecr.fecha_entrega_real <= ecr.fecha_entrega_est THEN 1 ELSE 0 END
    FROM EntregaConReferencia ecr
    LEFT JOIN AsignacionResuelta ar
        ON ar.entrega_id = ecr.entrega_id AND ar.rn = 1
    INNER JOIN governance_control.CLIENTE_CROSSWALK cw
        ON cw.source_pk = ecr.ventas_cliente_id AND cw.source_modulo = 'ventas' AND cw.is_survivor = 1
    INNER JOIN dw.Dim_Cliente dc
        ON dc.master_cliente_id = cw.master_cliente_id AND dc.es_version_actual = 1
    -- source_system matches 'CONDUCTOR' specifically: ASIGNACION_VEHICULO.conductor_id
    -- carries an enforced FK constraint, which can only reference flota.CONDUCTOR.
    LEFT JOIN governance_control.CONDUCTOR_CROSSWALK cwc
        ON cwc.source_pk = ar.conductor_id AND cwc.source_system = 'CONDUCTOR'
    LEFT JOIN dw.Dim_Conductor dcond
        ON dcond.master_conductor_id = cwc.master_conductor_id
    LEFT JOIN dw.Dim_Vehiculo dveh
        ON dveh.vehiculo_id = ar.vehiculo_id
    INNER JOIN dw.Dim_Ruta dr
        ON dr.ruta_id = ecr.ruta_id
    INNER JOIN dw.Dim_EstadoEntrega dee
        ON dee.codigo_estado = ecr.estado_entrega
    WHERE NOT EXISTS (SELECT 1 FROM dw.Fact_Entrega fe WHERE fe.entrega_id = ecr.entrega_id);
END;
GO

/* ============================================================================
   usp_Load_Fact_Incidente
   ----------------------------------------------------------------------------
   Same point-in-time resolution pattern as usp_Load_Fact_Entrega above:
   driver/vehicle for an incident are resolved via flota.ASIGNACION_VEHICULO
   at the incident's fecha_incidente.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dw.usp_Load_Fact_Incidente
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH AsignacionResueltaIncidente AS (
        SELECT
            i.incidente_id,
            av.conductor_id,
            av.vehiculo_id,
            ROW_NUMBER() OVER (PARTITION BY i.incidente_id ORDER BY av.fecha_inicio DESC) AS rn
        FROM operaciones.INCIDENTE i
        LEFT JOIN operaciones.PEDIDO p ON p.pedido_id = i.pedido_id
        LEFT JOIN flota.ASIGNACION_VEHICULO av
            ON av.pedido_id = p.pedido_id
           AND av.fecha_inicio <= i.fecha_incidente
           AND (av.fecha_fin IS NULL OR av.fecha_fin >= i.fecha_incidente)
    )
    INSERT INTO dw.Fact_Incidente
    (
        incidente_id, pedido_id, cliente_sk, conductor_sk, vehiculo_sk, ruta_sk,
        tiempo_incidente_sk, tipo_incidente, severidad, estado_resolucion,
        costo_estimado, dias_hasta_resolucion
    )
    SELECT
        i.incidente_id,
        i.pedido_id,
        dc.cliente_sk,
        dcond.conductor_sk,
        dveh.vehiculo_sk,
        dr.ruta_sk,
        CAST(FORMAT(i.fecha_incidente, 'yyyyMMdd') AS INT),
        i.tipo_incidente,
        i.severidad,
        i.estado_resolucion,
        i.costo_estimado,
        CASE WHEN i.fecha_resolucion IS NULL THEN NULL
             ELSE DATEDIFF(DAY, i.fecha_incidente, i.fecha_resolucion) END
    FROM operaciones.INCIDENTE i
    LEFT JOIN AsignacionResueltaIncidente ar
        ON ar.incidente_id = i.incidente_id AND ar.rn = 1
    LEFT JOIN operaciones.PEDIDO p
        ON p.pedido_id = i.pedido_id
    LEFT JOIN governance_control.CLIENTE_CROSSWALK cw
        ON cw.source_pk = p.cliente_id AND cw.source_modulo = 'ventas' AND cw.is_survivor = 1
    LEFT JOIN dw.Dim_Cliente dc
        ON dc.master_cliente_id = cw.master_cliente_id AND dc.es_version_actual = 1
    LEFT JOIN governance_control.CONDUCTOR_CROSSWALK cwc
        ON cwc.source_pk = ar.conductor_id AND cwc.source_system = 'CONDUCTOR'
    LEFT JOIN dw.Dim_Conductor dcond
        ON dcond.master_conductor_id = cwc.master_conductor_id
    LEFT JOIN dw.Dim_Vehiculo dveh
        ON dveh.vehiculo_id = ar.vehiculo_id
    LEFT JOIN operaciones.RUTA r
        ON r.ruta_id = p.ruta_id
    LEFT JOIN dw.Dim_Ruta dr
        ON dr.ruta_id = r.ruta_id
    WHERE NOT EXISTS (
        SELECT 1 FROM dw.Fact_Incidente fi WHERE fi.incidente_id = i.incidente_id
    );
END;
GO

/* ============================================================================
   EXECUTION PLAN / INDEX OPTIMIZATION NOTES (DBA practice deliverable)
   ----------------------------------------------------------------------------
   Run before/after with:
       SET STATISTICS IO, TIME ON;
       EXEC dw.usp_Load_Fact_Entrega;

   Expected bottleneck: the AsignacionResuelta CTE's LEFT JOIN on
   flota.ASIGNACION_VEHICULO with a range predicate (fecha_inicio/fecha_fin)
   is not seek-friendly with a single-column index. Recommended covering index
   on the source OLTP table (created here, not against PRIMARY-filegroup
   transactional load, only for the batch window of this ETL):

       CREATE NONCLUSTERED INDEX IX_AsignacionVehiculo_Pedido_Rango
           ON flota.ASIGNACION_VEHICULO (pedido_id, fecha_inicio, fecha_fin)
           INCLUDE (conductor_id, vehiculo_id);

   Without this index, expect a Clustered Index Scan on ASIGNACION_VEHICULO
   for every batch load, which is acceptable at current volume (~500K orders)
   but will not scale past a few million if TRANSTRACK's order volume grows.
   This tradeoff is documented explicitly instead of silently "working for now".
   ============================================================================ */
CREATE NONCLUSTERED INDEX IX_AsignacionVehiculo_Pedido_Rango
    ON flota.ASIGNACION_VEHICULO (pedido_id, fecha_inicio, fecha_fin)
    INCLUDE (conductor_id, vehiculo_id);
GO
