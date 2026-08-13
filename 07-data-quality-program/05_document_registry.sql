/* ============================================================================
   PROJECT  : P02 - Data Governance Architecture (TRANSTRACK)
   FOLDER   : 07-quality-program
   FILE     : 05_document_registry.sql
   PURPOSE  : Formal governance of documents attached to incidents
              (accident photos, digital signatures, damage reports):
              metadata, ownership, classification, retention, and a controlled
              lifecycle with an auditable trail. Documents cannot be
              hard-deleted; retirement is authorized and logged.

   DAMA-DMBOK2 alignment : Chapter 9 - Document & Content Management
              (retention, lifecycle, records governance).
              Reference: https://www.dama.org/

   ----------------------------------------------------------------------------
   OBJECT MAP
   ----------------------------------------------------------------------------
   DOCUMENT_RETENTION_POLICY   -- retention rules per document type
   DOCUMENT_REGISTRY           -- one row per governed document
   DOCUMENT_LIFECYCLE_LOG      -- append-only audit of every lifecycle event
   tr_DOCUMENT_REGISTRY_no_delete -- INSTEAD OF DELETE: blocks hard deletes
   usp_RegisterDocument        -- controlled insert (computes expiration)
   usp_EvaluateDocumentLifecycle -- active -> expiring -> archived transitions
   usp_RetireDocument          -- authorized soft-delete with audit trail

   LIFECYCLE STATES : active -> expiring -> archived -> deleted

   SCHEMA   : governance_control
   ============================================================================ */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ----------------------------------------------------------------------------
   1) RETENTION POLICY per document type.
   Different document types carry different legal retention windows.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID(N'governance_control.DOCUMENT_RETENTION_POLICY', N'U') IS NULL
BEGIN
    CREATE TABLE governance_control.DOCUMENT_RETENTION_POLICY
    (
        policy_id          INT IDENTITY(1,1) NOT NULL,
        document_type      VARCHAR(40)   NOT NULL,   -- e.g. ACCIDENT_PHOTO, DIGITAL_SIGNATURE, DAMAGE_REPORT
        description         NVARCHAR(200) NOT NULL,
        retention_days     INT           NOT NULL,   -- how long the document must be kept
        archive_after_expiry BIT         NOT NULL,   -- 1 = archive on expiry instead of allowing deletion
        legal_hold_default BIT           NOT NULL,   -- 1 = default under legal hold (never auto-retire)
        classification_level VARCHAR(20) NOT NULL,   -- PII|financiero_critico|operacional_sensible|publico
        is_active          BIT           NOT NULL CONSTRAINT DF_DRP_active DEFAULT (1),
        created_at         DATETIME2(3)  NOT NULL CONSTRAINT DF_DRP_created DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_DOCUMENT_RETENTION_POLICY PRIMARY KEY CLUSTERED (policy_id),
        CONSTRAINT UQ_DRP_type UNIQUE (document_type),
        CONSTRAINT CK_DRP_class CHECK
            (classification_level IN ('PII','financiero_critico','operacional_sensible','publico'))
    ) ON [PRIMARY];
    PRINT 'Created table governance_control.DOCUMENT_RETENTION_POLICY';
END
ELSE
    PRINT 'Table governance_control.DOCUMENT_RETENTION_POLICY already exists - skipping DDL';
GO

-- Seed / upsert retention policies (idempotent via MERGE on document_type)
DECLARE @policies TABLE
(
    document_type VARCHAR(40), description NVARCHAR(200), retention_days INT,
    archive_after_expiry BIT, legal_hold_default BIT, classification_level VARCHAR(20)
);

INSERT INTO @policies VALUES
('ACCIDENT_PHOTO',   'Photographs of accident scenes and vehicle damage', 3650, 1, 1, 'operacional_sensible'),
('DIGITAL_SIGNATURE','Recipient digital signatures proving delivery',      2555, 1, 0, 'PII'),
('DAMAGE_REPORT',    'Formal damage / loss assessment reports',            3650, 1, 1, 'financiero_critico'),
('POLICE_REPORT',    'Police reports linked to theft/accident incidents',  3650, 1, 1, 'operacional_sensible'),
('INSURANCE_CLAIM',  'Insurance claim documentation and correspondence',   2555, 1, 1, 'financiero_critico');

MERGE governance_control.DOCUMENT_RETENTION_POLICY AS tgt
USING @policies AS src
      ON tgt.document_type = src.document_type
WHEN MATCHED THEN
    UPDATE SET tgt.description = src.description,
               tgt.retention_days = src.retention_days,
               tgt.archive_after_expiry = src.archive_after_expiry,
               tgt.legal_hold_default = src.legal_hold_default,
               tgt.classification_level = src.classification_level
WHEN NOT MATCHED BY TARGET THEN
    INSERT (document_type, description, retention_days, archive_after_expiry,
            legal_hold_default, classification_level)
    VALUES (src.document_type, src.description, src.retention_days, src.archive_after_expiry,
            src.legal_hold_default, src.classification_level);
PRINT 'Retention policies upserted.';
GO

/* ----------------------------------------------------------------------------
   2) DOCUMENT_REGISTRY : one row per governed document.
   Note: the binary file itself is stored in a filesystem / object store; this
   table governs its metadata, ownership, retention and lifecycle.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID(N'governance_control.DOCUMENT_REGISTRY', N'U') IS NULL
BEGIN
    CREATE TABLE governance_control.DOCUMENT_REGISTRY
    (
        document_id        BIGINT IDENTITY(1,1) NOT NULL,

        -- Business linkage
        incidente_id       INT           NULL,        -- FK to operaciones.INCIDENTE (nullable: some docs are general)
        document_type      VARCHAR(40)   NOT NULL,    -- FK to DOCUMENT_RETENTION_POLICY.document_type

        -- File metadata
        file_name          NVARCHAR(260) NOT NULL,
        storage_uri        NVARCHAR(1000) NOT NULL,   -- path/URI to the actual binary
        mime_type          VARCHAR(100)  NOT NULL,
        file_size_kb       INT           NULL,
        content_sha256     CHAR(64)      NULL,        -- integrity hash of the binary

        -- Governance metadata
        classification_level VARCHAR(20) NOT NULL,    -- inherited from policy, snapshot at register time
        owner              NVARCHAR(128) NOT NULL,    -- accountable owner
        steward            NVARCHAR(128) NULL,        -- day-to-day steward

        -- Retention
        retention_days     INT           NOT NULL,    -- snapshot from policy
        created_at         DATETIME2(3)  NOT NULL CONSTRAINT DF_DR_created DEFAULT (SYSUTCDATETIME()),
        expiration_date    DATE          NOT NULL,    -- created_at + retention_days
        legal_hold         BIT           NOT NULL CONSTRAINT DF_DR_hold DEFAULT (0),

        -- Lifecycle
        lifecycle_status   VARCHAR(20)   NOT NULL CONSTRAINT DF_DR_status DEFAULT ('active'),
        archived_at        DATETIME2(3)  NULL,
        deleted_at         DATETIME2(3)  NULL,
        deletion_authorized_by NVARCHAR(128) NULL,
        deletion_reason    NVARCHAR(400) NULL,

        registered_by      NVARCHAR(128) NOT NULL CONSTRAINT DF_DR_regby DEFAULT (SUSER_SNAME()),

        CONSTRAINT PK_DOCUMENT_REGISTRY PRIMARY KEY CLUSTERED (document_id),
        CONSTRAINT CK_DR_status CHECK
            (lifecycle_status IN ('active','expiring','archived','deleted')),
        CONSTRAINT CK_DR_class CHECK
            (classification_level IN ('PII','financiero_critico','operacional_sensible','publico')),
        CONSTRAINT FK_DR_incidente FOREIGN KEY (incidente_id)
            REFERENCES operaciones.INCIDENTE (incidente_id)
    ) ON [PRIMARY];

    CREATE NONCLUSTERED INDEX IX_DR_incidente ON governance_control.DOCUMENT_REGISTRY (incidente_id);
    CREATE NONCLUSTERED INDEX IX_DR_status_expiry
        ON governance_control.DOCUMENT_REGISTRY (lifecycle_status, expiration_date)
        INCLUDE (document_type, legal_hold);

    PRINT 'Created table governance_control.DOCUMENT_REGISTRY';
END
ELSE
    PRINT 'Table governance_control.DOCUMENT_REGISTRY already exists - skipping DDL';
GO

/* ----------------------------------------------------------------------------
   3) DOCUMENT_LIFECYCLE_LOG : append-only audit trail of every lifecycle event.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID(N'governance_control.DOCUMENT_LIFECYCLE_LOG', N'U') IS NULL
BEGIN
    CREATE TABLE governance_control.DOCUMENT_LIFECYCLE_LOG
    (
        log_id         BIGINT IDENTITY(1,1) NOT NULL,
        document_id    BIGINT        NOT NULL,
        event_type     VARCHAR(30)   NOT NULL,   -- REGISTERED|MARK_EXPIRING|ARCHIVED|RETIRED|DELETE_BLOCKED
        from_status    VARCHAR(20)   NULL,
        to_status      VARCHAR(20)   NULL,
        event_detail   NVARCHAR(400) NULL,
        performed_by   NVARCHAR(128) NOT NULL CONSTRAINT DF_DLL_by DEFAULT (SUSER_SNAME()),
        performed_at   DATETIME2(3)  NOT NULL CONSTRAINT DF_DLL_at DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_DOCUMENT_LIFECYCLE_LOG PRIMARY KEY CLUSTERED (log_id)
    ) ON [PRIMARY];
    CREATE NONCLUSTERED INDEX IX_DLL_document ON governance_control.DOCUMENT_LIFECYCLE_LOG (document_id, performed_at);
    PRINT 'Created table governance_control.DOCUMENT_LIFECYCLE_LOG';
END
ELSE
    PRINT 'Table governance_control.DOCUMENT_LIFECYCLE_LOG already exists - skipping DDL';
GO

/* ----------------------------------------------------------------------------
   4) TRIGGER : block hard deletes.
   Physical DELETE is forbidden; documents must be retired via usp_RetireDocument
   (a soft UPDATE), which the trigger does not block. The attempt is logged.
   ---------------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER governance_control.tr_DOCUMENT_REGISTRY_no_delete
ON governance_control.DOCUMENT_REGISTRY
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;

    -- Record the blocked attempt for audit before refusing.
    INSERT INTO governance_control.DOCUMENT_LIFECYCLE_LOG
        (document_id, event_type, from_status, to_status, event_detail)
    SELECT d.document_id, 'DELETE_BLOCKED', d.lifecycle_status, d.lifecycle_status,
           'Hard DELETE rejected. Use usp_RetireDocument with authorization.'
    FROM deleted d;

    -- Leading ';' terminator is REQUIRED immediately before THROW (T-SQL rule).
    ;THROW 50050, 'Documents cannot be hard-deleted. Use governance_control.usp_RetireDocument.', 1;
END;
GO

/* ----------------------------------------------------------------------------
   5) usp_RegisterDocument : controlled insert.
   Snapshots classification + retention from policy and computes expiration.
   ---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE governance_control.usp_RegisterDocument
    @incidente_id  INT,
    @document_type VARCHAR(40),
    @file_name     NVARCHAR(260),
    @storage_uri   NVARCHAR(1000),
    @mime_type     VARCHAR(100),
    @file_size_kb  INT           = NULL,
    @content_sha256 CHAR(64)     = NULL,
    @owner         NVARCHAR(128),
    @steward       NVARCHAR(128) = NULL,
    @new_document_id BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @retention_days INT, @class VARCHAR(20), @hold BIT;

    SELECT @retention_days = retention_days,
           @class          = classification_level,
           @hold           = legal_hold_default
    FROM governance_control.DOCUMENT_RETENTION_POLICY
    WHERE document_type = @document_type AND is_active = 1;

    IF @retention_days IS NULL
    BEGIN
        ;THROW 50051, 'Unknown or inactive document_type. Define it in DOCUMENT_RETENTION_POLICY first.', 1;
    END

    DECLARE @now DATETIME2(3) = SYSUTCDATETIME();

    INSERT INTO governance_control.DOCUMENT_REGISTRY
        (incidente_id, document_type, file_name, storage_uri, mime_type, file_size_kb,
         content_sha256, classification_level, owner, steward, retention_days,
         created_at, expiration_date, legal_hold, lifecycle_status)
    VALUES
        (@incidente_id, @document_type, @file_name, @storage_uri, @mime_type, @file_size_kb,
         @content_sha256, @class, @owner, @steward, @retention_days,
         @now, DATEADD(DAY, @retention_days, CAST(@now AS DATE)), @hold, 'active');

    SET @new_document_id = SCOPE_IDENTITY();

    INSERT INTO governance_control.DOCUMENT_LIFECYCLE_LOG
        (document_id, event_type, from_status, to_status, event_detail)
    VALUES (@new_document_id, 'REGISTERED', NULL, 'active',
            CONCAT('Registered type=', @document_type, ' retention_days=', @retention_days));
END;
GO

/* ----------------------------------------------------------------------------
   6) usp_EvaluateDocumentLifecycle : scheduled transitions.
   active   -> expiring  when within 30 days of expiration (and not on hold)
   expiring -> archived  when past expiration and policy archives on expiry
   Documents under legal_hold are never auto-transitioned.
   ---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE governance_control.usp_EvaluateDocumentLifecycle
    @expiring_window_days INT = 30
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- active -> expiring
    UPDATE d
       SET d.lifecycle_status = 'expiring'
    OUTPUT inserted.document_id, 'MARK_EXPIRING', deleted.lifecycle_status, inserted.lifecycle_status,
           'Within expiring window'
    INTO governance_control.DOCUMENT_LIFECYCLE_LOG
           (document_id, event_type, from_status, to_status, event_detail)
    FROM governance_control.DOCUMENT_REGISTRY d
    WHERE d.lifecycle_status = 'active'
      AND d.legal_hold = 0
      AND d.expiration_date <= DATEADD(DAY, @expiring_window_days, @today);

    -- expiring -> archived (only if the policy archives on expiry)
    UPDATE d
       SET d.lifecycle_status = 'archived',
           d.archived_at = SYSUTCDATETIME()
    OUTPUT inserted.document_id, 'ARCHIVED', deleted.lifecycle_status, inserted.lifecycle_status,
           'Past expiration; archived per retention policy'
    INTO governance_control.DOCUMENT_LIFECYCLE_LOG
           (document_id, event_type, from_status, to_status, event_detail)
    FROM governance_control.DOCUMENT_REGISTRY d
    INNER JOIN governance_control.DOCUMENT_RETENTION_POLICY p
            ON p.document_type = d.document_type
    WHERE d.lifecycle_status = 'expiring'
      AND d.legal_hold = 0
      AND d.expiration_date < @today
      AND p.archive_after_expiry = 1;

    -- Report what is now in each state
    SELECT lifecycle_status, COUNT(*) AS document_count
    FROM governance_control.DOCUMENT_REGISTRY
    GROUP BY lifecycle_status
    ORDER BY lifecycle_status;
END;
GO

/* ----------------------------------------------------------------------------
   7) usp_RetireDocument : the ONLY authorized way to "delete".
   Performs a soft delete (status -> deleted) with mandatory authorization and
   a full audit entry. Refuses documents under legal hold.
   ---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE governance_control.usp_RetireDocument
    @document_id     BIGINT,
    @authorized_by   NVARCHAR(128),
    @reason          NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;

    IF @authorized_by IS NULL OR LTRIM(RTRIM(@authorized_by)) = ''
    BEGIN
        ;THROW 50052, 'Retirement requires an authorizer (@authorized_by).', 1;
    END

    DECLARE @status VARCHAR(20), @hold BIT;
    SELECT @status = lifecycle_status, @hold = legal_hold
    FROM governance_control.DOCUMENT_REGISTRY
    WHERE document_id = @document_id;

    IF @status IS NULL
    BEGIN
        ;THROW 50053, 'Document not found.', 1;
    END

    IF @hold = 1
    BEGIN
        ;THROW 50054, 'Document is under legal hold and cannot be retired.', 1;
    END

    IF @status = 'deleted'
    BEGIN
        ;THROW 50055, 'Document is already retired.', 1;
    END

    UPDATE governance_control.DOCUMENT_REGISTRY
       SET lifecycle_status       = 'deleted',
           deleted_at             = SYSUTCDATETIME(),
           deletion_authorized_by = @authorized_by,
           deletion_reason        = @reason
    WHERE document_id = @document_id;

    INSERT INTO governance_control.DOCUMENT_LIFECYCLE_LOG
        (document_id, event_type, from_status, to_status, event_detail)
    VALUES (@document_id, 'RETIRED', @status, 'deleted',
            CONCAT('Authorized by ', @authorized_by, ' | reason: ', @reason));
END;
GO

/* ============================================================================
   USAGE EXAMPLES (commented)
   ----------------------------------------------------------------------------
   -- Register a document:
   --   DECLARE @id BIGINT;
   --   EXEC governance_control.usp_RegisterDocument
   --        @incidente_id = 1001, @document_type = 'ACCIDENT_PHOTO',
   --        @file_name = 'inc1001_front.jpg', @storage_uri = 's3://transtrack/inc/1001/front.jpg',
   --        @mime_type = 'image/jpeg', @owner = 'legal.dept', @new_document_id = @id OUTPUT;
   --
   -- Run lifecycle evaluation (schedule this, e.g. nightly SQL Agent job):
   --   EXEC governance_control.usp_EvaluateDocumentLifecycle;
   --
   -- Attempt a hard delete (WILL be blocked and logged):
   --   DELETE FROM governance_control.DOCUMENT_REGISTRY WHERE document_id = 1;
   --
   -- Authorized retirement (the correct path):
   --   EXEC governance_control.usp_RetireDocument
   --        @document_id = 1, @authorized_by = 'ciso', @reason = 'Superseded by re-scan';
   ============================================================================ */

/* ============================================================================
   ARCHITECTURAL CONCLUSION (for README)
   ----------------------------------------------------------------------------
   Incident documents are records with legal weight, so they are governed like
   records: every document carries a policy-driven retention window, a
   classification, an accountable owner, and an immutable lifecycle history.
   Deletion is not an operation a user can perform - the INSTEAD OF DELETE
   trigger removes that capability entirely, and the only exit is an authorized,
   audited retirement that respects legal holds. This converts "we have some
   photos in a folder" into a defensible chain of custody.
   ============================================================================ */
