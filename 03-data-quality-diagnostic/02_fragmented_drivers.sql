-- =============================================================================
-- P02 | 02_fragmented_drivers.sql
-- One driver, three tables, no common key:
--   - CONDUCTOR: has license, no DPI
--   - EMPLEADO: has DPI, no license  
--   - OPERADOR: has neither, free-text plate
-- Legal gap: INCIDENTE has no conductor reference.
-- Only path: INCIDENTE > PEDIDO > ASIGNACION > CONDUCTOR - any break = untraceable.
-- =============================================================================

USE TRANSTRACK;
GO

-- -----------------------------------------------------------------------------
-- SECTION 1: Volume baseline per table
-- -----------------------------------------------------------------------------

SELECT 'SECTION 1 - Record Counts Per Module Table' AS diagnostic_section;

SELECT 'flota.CONDUCTOR (Operations)'  AS source_table, COUNT(*) AS total_records FROM flota.CONDUCTOR
UNION ALL
SELECT 'flota.EMPLEADO (HR)',                          COUNT(*) FROM flota.EMPLEADO
UNION ALL
SELECT 'flota.OPERADOR (GPS/Telemetry)',               COUNT(*) FROM flota.OPERADOR;

-- -----------------------------------------------------------------------------
-- SECTION 2: Name-based matching - the only available cross-table key
-- CONDUCTOR splits name into (nombre, apellido)
-- EMPLEADO splits name into (nombres, apellidos)
-- OPERADOR stores (nombre_completo) as a single field
-- We reconstruct a full name from each and attempt to match
-- -----------------------------------------------------------------------------

SELECT 'SECTION 2 - Cross-table name matching (best effort, no common key)' AS diagnostic_section;

WITH conductor_names AS (
    SELECT
        conductor_id,
        numero_licencia,
        UPPER(TRIM(nombre + ' ' + apellido))    AS full_name,
        SOUNDEX(nombre + ' ' + apellido)        AS sdx,
        categoria_licencia,
        fecha_vencimiento_licencia,
        activo
    FROM flota.CONDUCTOR
),
empleado_names AS (
    SELECT
        empleado_id,
        codigo_empleado,
        dpi,
        UPPER(TRIM(nombres + ' ' + apellidos))  AS full_name,
        SOUNDEX(nombres + ' ' + apellidos)      AS sdx,
        salario,
        cargo,
        departamento,
        activo
    FROM flota.EMPLEADO
),
operador_names AS (
    SELECT
        operador_id,
        id_operador,
        UPPER(TRIM(nombre_completo))            AS full_name,
        SOUNDEX(nombre_completo)                AS sdx,
        vehiculo_asignado,
        turno
    FROM flota.OPERADOR
)
-- Attempt 3-way match by SOUNDEX - closest we can get without a common key
SELECT
    c.conductor_id,
    e.empleado_id,
    o.operador_id,
    c.full_name                     AS name_in_conductor,
    e.full_name                     AS name_in_empleado,
    o.full_name                     AS name_in_operador,
    c.numero_licencia,
    e.dpi,
    e.codigo_empleado,
    o.id_operador,
    o.vehiculo_asignado,            -- This should match flota.VEHICULO.placa but has no FK
    c.categoria_licencia,
    c.fecha_vencimiento_licencia,
    e.salario,
    e.cargo,
    c.activo                        AS active_in_ops,
    e.activo                        AS active_in_hr,
    -- Name similarity scores
    DIFFERENCE(c.full_name, e.full_name)    AS similarity_ops_hr,
    DIFFERENCE(c.full_name, o.full_name)    AS similarity_ops_gps,
    -- Conflict: active in operations but inactive in HR?
    CASE
        WHEN c.activo = 1 AND e.activo = 0  THEN 'ACTIVE_OPS_INACTIVE_HR'
        WHEN c.activo = 0 AND e.activo = 1  THEN 'INACTIVE_OPS_ACTIVE_HR'
        ELSE 'STATUS_CONSISTENT'
    END                             AS status_conflict,
    -- Record completeness across the 3 tables
    'PRESENT_IN_ALL_3'              AS completeness
FROM conductor_names c
JOIN empleado_names e
    ON c.sdx = e.sdx
    AND DIFFERENCE(c.full_name, e.full_name) >= 3
JOIN operador_names o
    ON c.sdx = o.sdx
    AND DIFFERENCE(c.full_name, o.full_name) >= 3
ORDER BY similarity_ops_hr DESC, similarity_ops_gps DESC;

-- -----------------------------------------------------------------------------
-- SECTION 3: Drivers present in CONDUCTOR but with NO match in EMPLEADO
-- These are people driving trucks with no HR/payroll record
-- Risk: off-payroll drivers, subcontractors without formal documentation
-- -----------------------------------------------------------------------------

SELECT 'SECTION 3 - Drivers in Operations with NO HR record' AS diagnostic_section;

SELECT
    c.conductor_id,
    c.numero_licencia,
    UPPER(c.nombre + ' ' + c.apellido)     AS full_name,
    c.categoria_licencia,
    c.fecha_vencimiento_licencia,
    c.activo,
    -- How many route assignments does this person have?
    av.total_assignments,
    av.last_assignment_date,
    -- Expired license adds a compliance risk on top of missing HR record
    CASE
        WHEN c.fecha_vencimiento_licencia < GETDATE() THEN 'LICENSE_EXPIRED'
        WHEN c.fecha_vencimiento_licencia < DATEADD(DAY, 30, GETDATE()) THEN 'LICENSE_EXPIRING_SOON'
        ELSE 'LICENSE_VALID'
    END                                    AS license_status,
    'NO_HR_RECORD'                         AS risk_flag
FROM flota.CONDUCTOR c
-- No name match found in EMPLEADO
WHERE NOT EXISTS (
    SELECT 1
    FROM flota.EMPLEADO e
    WHERE SOUNDEX(e.nombres + ' ' + e.apellidos) = SOUNDEX(c.nombre + ' ' + c.apellido)
      AND DIFFERENCE(e.nombres + ' ' + e.apellidos, c.nombre + ' ' + c.apellido) >= 3
)
OUTER APPLY (
    SELECT
        COUNT(*)            AS total_assignments,
        MAX(fecha_inicio)   AS last_assignment_date
    FROM flota.ASIGNACION_VEHICULO av
    WHERE av.conductor_id = c.conductor_id
) av
ORDER BY av.total_assignments DESC, c.activo DESC;

-- -----------------------------------------------------------------------------
-- SECTION 4: OPERADOR with plate assigned but plate not in flota.VEHICULO
-- vehiculo_asignado is a free-text field - no FK - this is the second problem
-- -----------------------------------------------------------------------------

SELECT 'SECTION 4 - OPERADOR.vehiculo_asignado not in flota.VEHICULO' AS diagnostic_section;

SELECT
    o.operador_id,
    o.id_operador,
    o.nombre_completo,
    o.vehiculo_asignado,            -- This plate should exist in flota.VEHICULO
    o.turno,
    o.fecha_asignacion,
    v.vehiculo_id,                  -- NULL if plate not found
    v.estado                        AS vehicle_status,
    CASE
        WHEN o.vehiculo_asignado IS NULL    THEN 'NO_VEHICLE_ASSIGNED'
        WHEN v.vehiculo_id IS NULL          THEN 'GHOST_PLATE_NOT_IN_MASTER'
        WHEN v.estado = 'BAJA'             THEN 'ASSIGNED_TO_DECOMMISSIONED'
        WHEN v.estado = 'MANTENIMIENTO'    THEN 'ASSIGNED_TO_IN_MAINTENANCE'
        ELSE 'OK'
    END                             AS assignment_status
FROM flota.OPERADOR o
LEFT JOIN flota.VEHICULO v
    ON o.vehiculo_asignado = v.placa    -- String-to-string join, no FK
ORDER BY assignment_status, o.nombre_completo;

-- -----------------------------------------------------------------------------
-- SECTION 5: Legal gap - INCIDENTE has NO conductor reference
-- The path INCIDENTE > driver requires: INCIDENTE > PEDIDO > ASIGNACION > CONDUCTOR
-- If any link in that chain is broken, driver identity is unrecoverable
-- -----------------------------------------------------------------------------

SELECT 'SECTION 5 - Incident chain: how many incidents can be linked to a driver?' AS diagnostic_section;

SELECT
    i.incidente_id,
    i.fecha_incidente,
    i.tipo_incidente,
    i.severidad,
    i.estado_resolucion,
    i.costo_estimado,
    i.pedido_id,
    -- Step 1: Does the incident have a pedido?
    CASE WHEN i.pedido_id IS NULL THEN 'NO_PEDIDO' ELSE 'HAS_PEDIDO' END AS step1_pedido,
    -- Step 2: Does that pedido have an assignment?
    av.asignacion_id,
    CASE WHEN av.asignacion_id IS NULL THEN 'NO_ASSIGNMENT' ELSE 'HAS_ASSIGNMENT' END AS step2_assignment,
    -- Step 3: Does the assignment link to a conductor?
    av.conductor_id,
    c.nombre + ' ' + c.apellido    AS driver_name,
    c.numero_licencia,
    CASE WHEN c.conductor_id IS NULL THEN 'NO_DRIVER_FOUND' ELSE 'DRIVER_IDENTIFIED' END AS step3_driver,
    -- Step 4: Does that conductor have an HR record (DPI)?
    e.dpi,
    e.codigo_empleado,
    CASE WHEN e.empleado_id IS NULL THEN 'NO_HR_RECORD' ELSE 'HR_CONFIRMED' END AS step4_hr,
    -- Final: fully traceable?
    CASE
        WHEN i.pedido_id IS NOT NULL
         AND av.asignacion_id IS NOT NULL
         AND c.conductor_id IS NOT NULL
         AND e.empleado_id IS NOT NULL THEN 'FULLY_TRACEABLE'
        WHEN c.conductor_id IS NOT NULL THEN 'DRIVER_KNOWN_NO_HR'
        WHEN av.asignacion_id IS NOT NULL THEN 'ASSIGNMENT_EXISTS_NO_DRIVER'
        WHEN i.pedido_id IS NOT NULL THEN 'PEDIDO_EXISTS_NO_ASSIGNMENT'
        ELSE 'COMPLETELY_UNTRACEABLE'
    END                            AS traceability_status
FROM operaciones.INCIDENTE i
-- Join through the only path available: INCIDENTE > PEDIDO > ASIGNACION > CONDUCTOR
LEFT JOIN flota.ASIGNACION_VEHICULO av
    ON i.pedido_id = av.pedido_id
LEFT JOIN flota.CONDUCTOR c
    ON av.conductor_id = c.conductor_id
-- Try to find HR record by name match (no DPI in CONDUCTOR)
LEFT JOIN flota.EMPLEADO e
    ON DIFFERENCE(
        c.nombre + ' ' + c.apellido,
        e.nombres + ' ' + e.apellidos
    ) >= 3
ORDER BY traceability_status, i.severidad DESC;

-- Summary: traceability rate
SELECT
    traceability_status,
    COUNT(*)                AS incident_count,
    SUM(costo_estimado)     AS total_cost,
    CAST(
        100.0 * COUNT(*) / NULLIF((SELECT COUNT(*) FROM operaciones.INCIDENTE), 0)
    AS DECIMAL(5,2))        AS pct_of_total
FROM (
    SELECT
        i.incidente_id,
        i.costo_estimado,
        CASE
            WHEN i.pedido_id IS NOT NULL
             AND av.asignacion_id IS NOT NULL
             AND c.conductor_id IS NOT NULL
             AND e.empleado_id IS NOT NULL THEN 'FULLY_TRACEABLE'
            WHEN c.conductor_id IS NOT NULL THEN 'DRIVER_KNOWN_NO_HR'
            WHEN av.asignacion_id IS NOT NULL THEN 'ASSIGNMENT_EXISTS_NO_DRIVER'
            WHEN i.pedido_id IS NOT NULL THEN 'PEDIDO_EXISTS_NO_ASSIGNMENT'
            ELSE 'COMPLETELY_UNTRACEABLE'
        END AS traceability_status
    FROM operaciones.INCIDENTE i
    LEFT JOIN flota.ASIGNACION_VEHICULO av ON i.pedido_id = av.pedido_id
    LEFT JOIN flota.CONDUCTOR c ON av.conductor_id = c.conductor_id
    LEFT JOIN flota.EMPLEADO e
        ON DIFFERENCE(c.nombre + ' ' + c.apellido, e.nombres + ' ' + e.apellidos) >= 3
) x
GROUP BY traceability_status
ORDER BY incident_count DESC;

-- =============================================================================
