-- =============================================
-- TRANSTRACK | Week 02 | Part 4: Tables
-- Domain: Fleet
-- Intentional problems: 
--   - CONDUCTOR fragmented in 3 tables, no common key
--   - TELEMETRIA_GPS no formal relation to PEDIDO
-- =============================================

USE TRANSTRACK;
GO

-- -----------------------------------------------
-- VEHICULO
-- -----------------------------------------------
CREATE TABLE flota.VEHICULO (
    vehiculo_id       INT IDENTITY(1,1)     NOT NULL,
    placa             VARCHAR(10)           NOT NULL,
    marca             VARCHAR(50)           NOT NULL,
    modelo            VARCHAR(50)           NOT NULL,
    anio              INT                   NOT NULL,
    tipo_vehiculo     VARCHAR(50)           NOT NULL,
    capacidad_ton     DECIMAL(6,2)          NOT NULL,
    estado            VARCHAR(20)           NOT NULL DEFAULT 'ACTIVO',
    fecha_adquisicion DATE                  NOT NULL,
    km_actuales       DECIMAL(10,2)         NOT NULL DEFAULT 0,
    CONSTRAINT PK_VEHICULO PRIMARY KEY CLUSTERED (vehiculo_id)
        ON [PRIMARY],
    CONSTRAINT UQ_VEHICULO_PLACA UNIQUE (placa),
    CONSTRAINT CHK_VEHICULO_ESTADO CHECK (estado IN (
        'ACTIVO','MANTENIMIENTO','BAJA','RESERVA'
    ))
);
GO

-- -----------------------------------------------
-- CONDUCTOR (operations module)
-- Has: numero_licencia, no employee link
-- -----------------------------------------------
CREATE TABLE flota.CONDUCTOR (
    conductor_id      INT IDENTITY(1,1)     NOT NULL,
    numero_licencia   VARCHAR(20)           NOT NULL,
    nombre            VARCHAR(100)          NOT NULL,
    apellido          VARCHAR(100)          NOT NULL,
    telefono          VARCHAR(20)           NULL,
    categoria_licencia VARCHAR(10)          NOT NULL,
    fecha_vencimiento_licencia DATE         NOT NULL,
    activo            BIT                   NOT NULL DEFAULT 1,
    CONSTRAINT PK_CONDUCTOR PRIMARY KEY CLUSTERED (conductor_id)
        ON [PRIMARY]
    -- Intentional: no UNIQUE on numero_licencia
);
GO

-- -----------------------------------------------
-- EMPLEADO (HR module)
-- Has: codigo_empleado, no license link
-- Same people, different records, no common key
-- -----------------------------------------------
CREATE TABLE flota.EMPLEADO (
    empleado_id       INT IDENTITY(1,1)     NOT NULL,
    codigo_empleado   VARCHAR(20)           NOT NULL,
    nombres           VARCHAR(100)          NOT NULL,  -- different column name
    apellidos         VARCHAR(100)          NOT NULL,  -- different column name
    dpi               VARCHAR(20)           NULL,      -- national ID
    fecha_ingreso     DATE                  NOT NULL,
    cargo             VARCHAR(50)           NOT NULL,
    salario           DECIMAL(10,2)         NOT NULL,
    departamento      VARCHAR(50)           NULL,
    activo            BIT                   NOT NULL DEFAULT 1,
    CONSTRAINT PK_EMPLEADO PRIMARY KEY CLUSTERED (empleado_id)
        ON [PRIMARY],
    CONSTRAINT UQ_EMPLEADO_CODIGO UNIQUE (codigo_empleado)
    -- Intentional: no link to CONDUCTOR, no license column
);
GO

-- -----------------------------------------------
-- OPERADOR (GPS/telemetry module)
-- Has: id_operador, no license, no employee code
-- Third fragment of the same person
-- -----------------------------------------------
CREATE TABLE flota.OPERADOR (
    operador_id       INT IDENTITY(1,1)     NOT NULL,
    id_operador       VARCHAR(20)           NOT NULL,  -- internal GPS system ID
    nombre_completo   VARCHAR(200)          NOT NULL,  -- single field, not split
    email             VARCHAR(100)          NULL,
    turno             VARCHAR(20)           NOT NULL DEFAULT 'DIURNO',
    vehiculo_asignado VARCHAR(10)           NULL,      -- plate as text, no FK
    fecha_asignacion  DATE                  NULL,
    CONSTRAINT PK_OPERADOR PRIMARY KEY CLUSTERED (operador_id)
        ON [PRIMARY],
    CONSTRAINT UQ_OPERADOR_ID UNIQUE (id_operador)
    -- Intentional: vehiculo_asignado is text, not FK to VEHICULO
    -- Intentional: no link to CONDUCTOR or EMPLEADO
);
GO

-- -----------------------------------------------
-- ASIGNACION_VEHICULO
-- Links driver to vehicle per trip
-- References CONDUCTOR only (not EMPLEADO/OPERADOR)
-- -----------------------------------------------
CREATE TABLE flota.ASIGNACION_VEHICULO (
    asignacion_id     INT IDENTITY(1,1)     NOT NULL,
    vehiculo_id       INT                   NOT NULL,
    conductor_id      INT                   NOT NULL,
    pedido_id         INT                   NULL,
    fecha_inicio      DATETIME2             NOT NULL,
    fecha_fin         DATETIME2             NULL,
    km_inicio         DECIMAL(10,2)         NOT NULL,
    km_fin            DECIMAL(10,2)         NULL,
    CONSTRAINT PK_ASIGNACION PRIMARY KEY CLUSTERED (asignacion_id)
        ON [PRIMARY],
    CONSTRAINT FK_ASIGNACION_VEHICULO 
        FOREIGN KEY (vehiculo_id) REFERENCES flota.VEHICULO(vehiculo_id),
    CONSTRAINT FK_ASIGNACION_CONDUCTOR 
        FOREIGN KEY (conductor_id) REFERENCES flota.CONDUCTOR(conductor_id),
    CONSTRAINT FK_ASIGNACION_PEDIDO
        FOREIGN KEY (pedido_id) REFERENCES operaciones.PEDIDO(pedido_id)
);
GO

-- -----------------------------------------------
-- TELEMETRIA_GPS (no partition — raw state)
-- Intentional: vehiculo_id as INT but no FK
-- No formal relation to PEDIDO
-- -----------------------------------------------
CREATE TABLE flota.TELEMETRIA_GPS (
    telemetria_id     BIGINT IDENTITY(1,1)  NOT NULL,
    vehiculo_id       INT                   NOT NULL, -- no FK intentional
    fecha_hora        DATETIME2             NOT NULL,
    latitud           DECIMAL(10,7)         NOT NULL,
    longitud          DECIMAL(10,7)         NOT NULL,
    velocidad_kmh     DECIMAL(5,2)          NOT NULL,
    rumbo             DECIMAL(5,2)          NULL,
    altitud_m         DECIMAL(8,2)          NULL,
    evento            VARCHAR(30)           NULL,
    -- Intentional: no pedido_id, no conductor_id
    -- Cannot formally link GPS record to active order
    CONSTRAINT PK_TELEMETRIA PRIMARY KEY CLUSTERED (telemetria_id)
        ON [ARCHIVE]
);
GO