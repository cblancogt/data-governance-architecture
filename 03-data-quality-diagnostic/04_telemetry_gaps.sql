-- =============================================================================
-- P02 | 04_telemetry_gaps.sql
-- Identifies GPS records that cannot be linked to any operation:
--   - Ghost vehicles: transmitting but not in flota.VEHICULO
--   - Unassigned movement: vehicle moving with no active order
--   - Dark windows: active assignments with no GPS signal
-- Note: TELEMETRIA_GPS has no FK, no pedido_id, no conductor_id by design.
-- =============================================================================
USE TRANSTRACK;
GO

-- Working window: last 90 days (adjust for full audit)
DECLARE @window_start DATETIME2 = DATEADD(DAY, -90, GETDATE());
DECLARE @window_end   DATETIME2 = GETDATE();
DECLARE @signal_interval_min INT = 5;         -- Expected GPS signal every 5 minutes

-- -----------------------------------------------------------------------------
-- SECTION 0: Table size and date range sanity check
-- Always check before running 50M row queries
-- -----------------------------------------------------------------------------

SELECT 'SECTION 0 - TELEMETRIA_GPS size and date range' AS diagnostic_section;

SELECT
    COUNT(*)                        AS total_gps_records,
    MIN(fecha_hora)                 AS earliest_record,
    MAX(fecha_hora)                 AS latest_record,
    COUNT(DISTINCT vehiculo_id)     AS distinct_vehicles_in_telemetry,
    (SELECT COUNT(*) FROM flota.VEHICULO WHERE estado = 'ACTIVO') AS active_vehicles_in_master,
    -- Records in our working window
    SUM(CASE WHEN fecha_hora >= @window_start THEN 1 ELSE 0 END) AS records_in_90d_window
FROM flota.TELEMETRIA_GPS;

-- -----------------------------------------------------------------------------
-- SECTION 1: Ghost vehicles — transmitting in GPS but not in flota.VEHICULO
-- TELEMETRIA_GPS.vehiculo_id has no FK — any integer can appear here
-- -----------------------------------------------------------------------------

SELECT 'SECTION 1 - Ghost vehicles: in telemetry, not in VEHICULO master' AS diagnostic_section;

SELECT
    t.vehiculo_id                   AS ghost_vehicle_id,
    COUNT(*)                        AS gps_record_count,
    MIN(t.fecha_hora)               AS first_signal,
    MAX(t.fecha_hora)               AS last_signal,
    AVG(t.velocidad_kmh)            AS avg_speed_kmh,
    MAX(t.velocidad_kmh)            AS max_speed_kmh,
    -- Is this vehicle moving? Could be sensor error or unauthorized device
    CASE
        WHEN AVG(t.velocidad_kmh) > 60 THEN 'ACTIVELY_MOVING_NO_RECORD'
        WHEN AVG(t.velocidad_kmh) > 0  THEN 'OCCASIONAL_MOVEMENT_NO_RECORD'
        ELSE 'STATIONARY_UNKNOWN_DEVICE'
    END                             AS risk_classification
FROM flota.TELEMETRIA_GPS t
LEFT JOIN flota.VEHICULO v ON t.vehiculo_id = v.vehiculo_id
WHERE t.fecha_hora >= @window_start
  AND v.vehiculo_id IS NULL         -- Not in master table
GROUP BY t.vehiculo_id
ORDER BY gps_record_count DESC;

-- -----------------------------------------------------------------------------
-- SECTION 2: GPS records with no assignment overlap
-- For each GPS point, try to find a matching ASIGNACION_VEHICULO window.
-- If none found, the vehicle was moving without a formal mission.
-- NOTE: ASIGNACION.pedido_id is nullable — assignment may exist without an order.
-- -----------------------------------------------------------------------------

SELECT 'SECTION 2 - GPS signals with no matching assignment (sample 90 days)' AS diagnostic_section;

-- Aggregate by vehicle to avoid row-by-row output of 50M records
SELECT
    t.vehiculo_id,
    v.placa,
    v.estado                        AS vehicle_status,
    COUNT(*)                        AS total_gps_points_in_window,
    -- Points with no overlapping assignment
    SUM(CASE WHEN av.asignacion_id IS NULL THEN 1 ELSE 0 END) AS unassigned_gps_points,
    CAST(
        100.0 * SUM(CASE WHEN av.asignacion_id IS NULL THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0)
    AS DECIMAL(5,2))                AS pct_unassigned,
    SUM(CASE WHEN av.asignacion_id IS NULL AND t.velocidad_kmh > 60 THEN 1 ELSE 0 END) AS high_speed_unassigned,
    MAX(CASE WHEN av.asignacion_id IS NULL THEN t.fecha_hora END) AS last_unassigned_signal
FROM flota.TELEMETRIA_GPS t
LEFT JOIN flota.VEHICULO v
    ON t.vehiculo_id = v.vehiculo_id
LEFT JOIN flota.ASIGNACION_VEHICULO av
    ON  t.vehiculo_id   = av.vehiculo_id
    AND t.fecha_hora   >= av.fecha_inicio
    AND t.fecha_hora   <= COALESCE(av.fecha_fin, GETDATE())
WHERE t.fecha_hora >= @window_start
  AND t.fecha_hora <  @window_end
  AND t.velocidad_kmh > 5           -- Exclude parked/stationary (noise filter)
GROUP BY t.vehiculo_id, v.placa, v.estado
HAVING SUM(CASE WHEN av.asignacion_id IS NULL THEN 1 ELSE 0 END) > 0
ORDER BY pct_unassigned DESC, unassigned_gps_points DESC;

-- -----------------------------------------------------------------------------
-- SECTION 3: Active assignments with GPS dark windows
-- For each ASIGNACION in the window, calculate expected vs actual GPS signals.
-- Expected: 1 signal per 5 minutes = 12 per hour.
-- A "dark window" is >30 consecutive minutes with no signal.
-- -----------------------------------------------------------------------------

SELECT 'SECTION 3 - Assignments with GPS dark windows (signal gaps)' AS diagnostic_section;

SELECT
    av.asignacion_id,
    av.vehiculo_id,
    v.placa,
    av.conductor_id,
    c.nombre + ' ' + c.apellido     AS driver_name,
    av.pedido_id,
    av.fecha_inicio,
    av.fecha_fin,
    -- Assignment duration in minutes
    DATEDIFF(MINUTE, av.fecha_inicio, COALESCE(av.fecha_fin, GETDATE())) AS assignment_duration_min,
    -- Expected GPS points at 1 per 5 minutes
    DATEDIFF(MINUTE, av.fecha_inicio, COALESCE(av.fecha_fin, GETDATE())) / @signal_interval_min
                                    AS expected_gps_points,
    -- Actual GPS points received
    gps_data.actual_gps_points,
    -- Coverage rate
    CAST(
        100.0 * gps_data.actual_gps_points
        / NULLIF(
            DATEDIFF(MINUTE, av.fecha_inicio, COALESCE(av.fecha_fin, GETDATE())) / @signal_interval_min, 0
          )
    AS DECIMAL(5,2))                AS gps_coverage_pct,
    -- Classify the gap severity
    CASE
        WHEN gps_data.actual_gps_points = 0 THEN 'COMPLETE_BLACKOUT'
        WHEN gps_data.actual_gps_points <
             DATEDIFF(MINUTE, av.fecha_inicio, COALESCE(av.fecha_fin, GETDATE())) / @signal_interval_min * 0.25
                                    THEN 'SEVERE_GAP_OVER_75PCT_MISSING'
        WHEN gps_data.actual_gps_points <
             DATEDIFF(MINUTE, av.fecha_inicio, COALESCE(av.fecha_fin, GETDATE())) / @signal_interval_min * 0.50
                                    THEN 'MODERATE_GAP_50_75PCT_MISSING'
        ELSE 'MINOR_GAP'
    END                             AS signal_gap_severity
FROM flota.ASIGNACION_VEHICULO av
LEFT JOIN flota.VEHICULO v ON av.vehiculo_id = v.vehiculo_id
LEFT JOIN flota.CONDUCTOR c ON av.conductor_id = c.conductor_id
OUTER APPLY (
    SELECT COUNT(*) AS actual_gps_points
    FROM flota.TELEMETRIA_GPS t
    WHERE t.vehiculo_id = av.vehiculo_id
      AND t.fecha_hora >= av.fecha_inicio
      AND t.fecha_hora <= COALESCE(av.fecha_fin, GETDATE())
      AND t.fecha_hora >= @window_start   -- Keep the date filter even in APPLY
) AS gps_data
WHERE av.fecha_inicio >= @window_start
  AND (
    gps_data.actual_gps_points = 0
    OR gps_data.actual_gps_points <
       DATEDIFF(MINUTE, av.fecha_inicio, COALESCE(av.fecha_fin, GETDATE())) / @signal_interval_min * 0.50
  )
ORDER BY signal_gap_severity, av.fecha_inicio DESC;

-- -----------------------------------------------------------------------------
-- SECTION 4: Active vehicles in VEHICULO with no GPS in last 30 days
-- Vehicle is supposed to be active but has gone dark
-- -----------------------------------------------------------------------------

SELECT 'SECTION 4 - Active vehicles with no GPS signal in last 30 days' AS diagnostic_section;

DECLARE @recent_cutoff DATETIME2 = DATEADD(DAY, -30, GETDATE());

SELECT
    v.vehiculo_id,
    v.placa,
    v.marca,
    v.modelo,
    v.tipo_vehiculo,
    v.estado,
    v.km_actuales,
    last_signal.last_gps_time,
    DATEDIFF(DAY, last_signal.last_gps_time, GETDATE()) AS days_since_last_signal,
    CASE
        WHEN last_signal.last_gps_time IS NULL THEN 'NEVER_TRANSMITTED'
        ELSE 'GONE_DARK'
    END                             AS status
FROM flota.VEHICULO v
LEFT JOIN (
    SELECT
        vehiculo_id,
        MAX(fecha_hora) AS last_gps_time
    FROM flota.TELEMETRIA_GPS
    WHERE fecha_hora >= DATEADD(DAY, -365, GETDATE())   -- Limit scan to 1 year
    GROUP BY vehiculo_id
) last_signal ON v.vehiculo_id = last_signal.vehiculo_id
WHERE v.estado = 'ACTIVO'
  AND (last_signal.last_gps_time IS NULL OR last_signal.last_gps_time < @recent_cutoff)
ORDER BY days_since_last_signal DESC;

-- -----------------------------------------------------------------------------
-- SECTION 5: Executive GPS gap summary
-- -----------------------------------------------------------------------------

SELECT 'SECTION 5 - Executive Telemetry Gap Summary' AS diagnostic_section;

SELECT
    (SELECT COUNT(DISTINCT vehiculo_id) FROM flota.TELEMETRIA_GPS WHERE fecha_hora >= @window_start) AS vehicles_transmitting_90d,
    (SELECT COUNT(*) FROM flota.VEHICULO WHERE estado = 'ACTIVO')                                    AS active_vehicles_in_master,
    (
        SELECT COUNT(DISTINCT t.vehiculo_id)
        FROM flota.TELEMETRIA_GPS t
        LEFT JOIN flota.VEHICULO v ON t.vehiculo_id = v.vehiculo_id
        WHERE t.fecha_hora >= @window_start AND v.vehiculo_id IS NULL
    )                                                                                                AS ghost_vehicles,
    (
        SELECT COUNT(*) FROM flota.TELEMETRIA_GPS
        WHERE fecha_hora >= @window_start
    )                                                                                                AS total_gps_records_90d,
    'NO PEDIDO/CONDUCTOR COLUMNS IN TELEMETRIA_GPS — LINKAGE REQUIRES ASIGNACION JOIN' AS governance_gap_note;
