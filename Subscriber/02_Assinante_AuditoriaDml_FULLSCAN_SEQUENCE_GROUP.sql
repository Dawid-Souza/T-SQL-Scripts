/*
    Estrutura persistente do coletor. O script e idempotente: uma nova execucao
    preserva os eventos ja coletados e apenas atualiza configuracoes/procedure.
*/
USE [{{SUBSCRIBER_CONTROL_DATABASE}}];
GO

IF OBJECT_ID(N'dbo.ReplAuditDatabase', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReplAuditDatabase
    (
          NM_DATABASE SYSNAME NOT NULL
        , IC_ATIVO BIT NOT NULL
            CONSTRAINT DF_ReplAuditDatabase_IC_ATIVO DEFAULT (1)
        , CONSTRAINT PK_ReplAuditDatabase PRIMARY KEY CLUSTERED (NM_DATABASE)
    );
END;

IF OBJECT_ID(N'dbo.ReplAuditExcludedPrincipal', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReplAuditExcludedPrincipal
    (
          NM_PRINCIPAL SYSNAME NOT NULL
        , IC_ATIVO BIT NOT NULL
            CONSTRAINT DF_ReplAuditExcludedPrincipal_IC_ATIVO DEFAULT (1)
        , CONSTRAINT PK_ReplAuditExcludedPrincipal PRIMARY KEY CLUSTERED (NM_PRINCIPAL)
    );
END;

IF OBJECT_ID(N'dbo.ReplAuditSettings', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReplAuditSettings
    (
          NM_CHAVE SYSNAME NOT NULL
        , VL_VALOR NVARCHAR(2048) NULL
        , CONSTRAINT PK_ReplAuditSettings PRIMARY KEY CLUSTERED (NM_CHAVE)
    );
END;
GO

DELETE FROM dbo.ReplAuditDatabase;
INSERT INTO dbo.ReplAuditDatabase (NM_DATABASE, IC_ATIVO)
SELECT V.NM_DATABASE, 1
FROM
(
    VALUES
    {{DATABASE_VALUES}}
) AS V(NM_DATABASE);

DELETE FROM dbo.ReplAuditExcludedPrincipal;
{{EXCLUDED_PRINCIPAL_INSERT}}

MERGE dbo.ReplAuditSettings AS T
USING
(
    VALUES
          (N'AuditName', N'{{AUDIT_NAME_STRING}}')
        , (N'AuditPath', {{AUDIT_PATH_LITERAL}})
        , (N'EmailEnabled', N'{{EMAIL_ENABLED_STRING}}')
        , (N'DatabaseMailProfile', N'{{EMAIL_PROFILE_STRING}}')
        , (N'EmailRecipients', N'{{EMAIL_RECIPIENTS_STRING}}')
) AS S(NM_CHAVE, VL_VALOR)
ON T.NM_CHAVE = S.NM_CHAVE
WHEN MATCHED THEN
    UPDATE SET VL_VALOR = S.VL_VALOR
WHEN NOT MATCHED THEN
    INSERT (NM_CHAVE, VL_VALOR) VALUES (S.NM_CHAVE, S.VL_VALOR);
GO

IF OBJECT_ID(N'dbo.AuditoriaDml', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AuditoriaDml
    (
          ID                    BIGINT IDENTITY(1,1) NOT NULL
        , DT_EVENTO             DATETIME2(7) NOT NULL
        , NM_USUARIO            SYSNAME NULL
        , NM_HOST               NVARCHAR(128) NULL
        , NM_APLICACAO          NVARCHAR(256) NULL
        , NM_SERVIDOR_LOCAL     SYSNAME NOT NULL
        , NM_DATABASE           SYSNAME NOT NULL
        , NM_SCHEMA             SYSNAME NULL
        , NM_OBJETO             SYSNAME NULL
        , TP_OPERACAO           VARCHAR(10) NOT NULL
        , CD_ACAO               VARCHAR(4) NOT NULL
        , ID_SESSAO             SMALLINT NULL
        , ID_TRANSACAO          BIGINT NULL
        , DS_COMANDO            NVARCHAR(MAX) NULL
        , ST_PROCESSAMENTO      VARCHAR(30) NOT NULL
            CONSTRAINT DF_AuditoriaDml_ST_PROCESSAMENTO DEFAULT ('PENDENTE_VERIFICACAO')
        , ID_REPL_DIST_DIFF     BIGINT NULL
        , DT_PROCESSAMENTO      DATETIME2(3) NULL
        , DS_MENSAGEM           NVARCHAR(4000) NULL
        , NM_ARQUIVO_AUDIT      NVARCHAR(260) NOT NULL
        , NR_OFFSET_AUDIT       BIGINT NOT NULL
        , ID_GRUPO_SEQUENCIA    VARBINARY(85) NULL
        , NR_SEQUENCIA_AUDIT    INT NOT NULL
        , ID_EVENTO_AUDIT       VARBINARY(32) NOT NULL
        , CONSTRAINT PK_AuditoriaDml PRIMARY KEY CLUSTERED (ID)
    );
END;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.AuditoriaDml')
      AND [name] = N'UX_AuditoriaDml_EventoAudit'
)
BEGIN
    CREATE UNIQUE INDEX UX_AuditoriaDml_EventoAudit
        ON dbo.AuditoriaDml (ID_EVENTO_AUDIT);
END;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.AuditoriaDml')
      AND [name] = N'IX_AuditoriaDml_Processamento'
)
BEGIN
    CREATE INDEX IX_AuditoriaDml_Processamento
        ON dbo.AuditoriaDml
        (
              ST_PROCESSAMENTO
            , NM_DATABASE
            , NM_SCHEMA
            , NM_OBJETO
            , ID
        )
        INCLUDE (ID_REPL_DIST_DIFF, DT_EVENTO, TP_OPERACAO);
END;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.AuditoriaDml')
      AND [name] = N'IX_AuditoriaDml_ReplDistDiff'
)
BEGIN
    CREATE INDEX IX_AuditoriaDml_ReplDistDiff
        ON dbo.AuditoriaDml (ID_REPL_DIST_DIFF, ST_PROCESSAMENTO)
        WHERE ID_REPL_DIST_DIFF IS NOT NULL;
END;

IF OBJECT_ID(N'dbo.AuditoriaDmlControle', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AuditoriaDmlControle
    (
          ID                      TINYINT NOT NULL
        , NM_AUDIT                SYSNAME NOT NULL
        , NM_FILE_PATTERN         NVARCHAR(260) NOT NULL
        , DT_ULTIMA_COLETA        DATETIME2(3) NOT NULL
        , NR_EVENTOS_LIDOS        BIGINT NOT NULL
        , NR_EVENTOS_VALIDOS      BIGINT NOT NULL
        , NR_EVENTOS_INSERIDOS    BIGINT NOT NULL
        , CONSTRAINT PK_AuditoriaDmlControle PRIMARY KEY CLUSTERED (ID)
        , CONSTRAINT CK_AuditoriaDmlControle_ID CHECK (ID = 1)
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.SpAuditoriaDmlCapturar
(
    @FilePattern NVARCHAR(260) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
          @SQLPath NVARCHAR(260)
        , @AuditPath NVARCHAR(260)
        , @AuditName SYSNAME
        , @QtdEventosLidos BIGINT = 0
        , @QtdEventosValidos BIGINT = 0
        , @QtdInseridos BIGINT = 0
        , @LockResult INT
        , @LockResource NVARCHAR(255) = DB_NAME() + N'.dbo.SpAuditoriaDmlCapturar';

    EXEC @LockResult = sys.sp_getapplock
          @Resource = @LockResource
        , @LockMode = N'Exclusive'
        , @LockOwner = N'Session'
        , @LockTimeout = 0;

    IF @LockResult < 0
    BEGIN
        SELECT
              CAST(N'COLETA_JA_EM_EXECUCAO' AS VARCHAR(30)) AS ST_EXECUCAO
            , @FilePattern AS NM_FILE_PATTERN
            , CAST(0 AS BIGINT) AS NR_EVENTOS_LIDOS
            , CAST(0 AS BIGINT) AS NR_EVENTOS_VALIDOS
            , CAST(0 AS BIGINT) AS NR_EVENTOS_INSERIDOS;
        RETURN;
    END;

    BEGIN TRY
        IF NULLIF(LTRIM(RTRIM(@FilePattern)), N'') IS NULL
        BEGIN
            SELECT @AuditPath = NULLIF(LTRIM(RTRIM(VL_VALOR)), N'')
            FROM dbo.ReplAuditSettings
            WHERE NM_CHAVE = N'AuditPath';

            SELECT @AuditName = NULLIF(LTRIM(RTRIM(VL_VALOR)), N'')
            FROM dbo.ReplAuditSettings
            WHERE NM_CHAVE = N'AuditName';

            IF @AuditName IS NULL
                THROW 50000, 'AuditName nao configurado em dbo.ReplAuditSettings.', 1;

            IF @AuditPath IS NULL
            BEGIN
                EXEC master.dbo.xp_instance_regread
                      N'HKEY_LOCAL_MACHINE'
                    , N'Software\Microsoft\MSSQLServer\Setup'
                    , N'SQLPath'
                    , @SQLPath OUTPUT;

                IF NULLIF(LTRIM(RTRIM(@SQLPath)), N'') IS NULL
                    THROW 50001, 'Nao foi possivel identificar o SQLPath da instancia.', 1;

                SET @SQLPath =
                    CASE WHEN RIGHT(@SQLPath, 1) IN (N'\', N'/')
                         THEN LEFT(@SQLPath, LEN(@SQLPath) - 1)
                         ELSE @SQLPath END;

                SET @AuditPath = @SQLPath + N'\Audit\';
            END;

            IF RIGHT(@AuditPath, 1) NOT IN (N'\', N'/')
                SET @AuditPath += N'\';

            SET @FilePattern = @AuditPath + @AuditName + N'_*.sqlaudit';
        END;

        CREATE TABLE #AuditSource
        (
              event_time DATETIME2(7) NOT NULL
            , sequence_number INT NOT NULL
            , sequence_group_id VARBINARY(85) NULL
            , action_id VARCHAR(4) NOT NULL
            , session_id SMALLINT NULL
            , transaction_id BIGINT NULL
            , server_principal_name SYSNAME NULL
            , session_server_principal_name SYSNAME NULL
            , server_instance_name SYSNAME NULL
            , database_name SYSNAME NULL
            , schema_name SYSNAME NULL
            , object_name SYSNAME NULL
            , statement NVARCHAR(4000) NULL
            , file_name NVARCHAR(260) NOT NULL
            , audit_file_offset BIGINT NOT NULL
            , host_name NVARCHAR(128) NULL
            , application_name NVARCHAR(256) NULL
        );

        INSERT INTO #AuditSource
        SELECT
              A.event_time
            , A.sequence_number
            , A.sequence_group_id
            , A.action_id
            , A.session_id
            , A.transaction_id
            , A.server_principal_name
            , A.session_server_principal_name
            , A.server_instance_name
            , A.database_name
            , A.schema_name
            , A.object_name
            , A.statement
            , A.file_name
            , A.audit_file_offset
            , A.host_name
            , A.application_name
        FROM sys.fn_get_audit_file(@FilePattern, NULL, NULL) AS A;

        SELECT @QtdEventosLidos = COUNT_BIG(*) FROM #AuditSource;

        SELECT
              A.*
            , X.NM_ACAO
            , HASHBYTES
              (
                  'SHA2_256',
                  CONVERT
                  (
                      NVARCHAR(MAX),
                        N'FILE=' + ISNULL(A.file_name, N'<NULL>')
                      + N'|GROUP=' + ISNULL(CONVERT(NVARCHAR(170), A.sequence_group_id, 1), N'<NULL>')
                      + N'|SEQ=' + ISNULL(CONVERT(NVARCHAR(30), A.sequence_number), N'<NULL>')
                      + N'|TIME=' + ISNULL(CONVERT(NVARCHAR(33), A.event_time, 126), N'<NULL>')
                      + N'|OFFSET=' + ISNULL(CONVERT(NVARCHAR(30), A.audit_file_offset), N'<NULL>')
                      + N'|ACTION=' + ISNULL(A.action_id, N'<NULL>')
                      + N'|SESSION=' + ISNULL(CONVERT(NVARCHAR(30), A.session_id), N'<NULL>')
                      + N'|TRAN=' + ISNULL(CONVERT(NVARCHAR(30), A.transaction_id), N'<NULL>')
                      + N'|DB=' + ISNULL(A.database_name, N'<NULL>')
                      + N'|SCHEMA=' + ISNULL(A.schema_name, N'<NULL>')
                      + N'|OBJECT=' + ISNULL(A.object_name, N'<NULL>')
                      + N'|SERVERUSER=' + ISNULL(A.server_principal_name, N'<NULL>')
                      + N'|SESSIONUSER=' + ISNULL(A.session_server_principal_name, N'<NULL>')
                      + N'|STATEMENT=' + ISNULL(A.statement, N'<NULL>')
                  )
              ) AS ID_EVENTO_AUDIT
        INTO #FonteFinal
        FROM #AuditSource AS A
        CROSS APPLY
        (
            SELECT TOP (1) D.[name] AS NM_ACAO
            FROM sys.dm_audit_actions AS D
            WHERE D.action_id = A.action_id
              AND D.[name] IN (N'INSERT', N'UPDATE', N'DELETE')
            ORDER BY D.[name]
        ) AS X
        WHERE EXISTS
        (
            SELECT 1
            FROM dbo.ReplAuditDatabase AS C
            WHERE C.IC_ATIVO = 1
              AND C.NM_DATABASE = A.database_name
        )
        AND NOT EXISTS
        (
            SELECT 1
            FROM dbo.ReplAuditExcludedPrincipal AS P
            WHERE P.IC_ATIVO = 1
              AND
              (
                   P.NM_PRINCIPAL = ISNULL(A.server_principal_name, N'')
                OR P.NM_PRINCIPAL = ISNULL(A.session_server_principal_name, N'')
              )
        )
        AND A.schema_name IS NOT NULL
        AND A.object_name IS NOT NULL;

        SELECT @QtdEventosValidos = COUNT_BIG(*) FROM #FonteFinal;

        INSERT INTO dbo.AuditoriaDml
        (
              DT_EVENTO, NM_USUARIO, NM_HOST, NM_APLICACAO, NM_SERVIDOR_LOCAL
            , NM_DATABASE, NM_SCHEMA, NM_OBJETO, TP_OPERACAO, CD_ACAO
            , ID_SESSAO, ID_TRANSACAO, DS_COMANDO, ST_PROCESSAMENTO
            , ID_REPL_DIST_DIFF, DT_PROCESSAMENTO, DS_MENSAGEM
            , NM_ARQUIVO_AUDIT, NR_OFFSET_AUDIT, ID_GRUPO_SEQUENCIA
            , NR_SEQUENCIA_AUDIT, ID_EVENTO_AUDIT
        )
        SELECT
              F.event_time
            , COALESCE(F.session_server_principal_name, F.server_principal_name)
            , F.host_name
            , F.application_name
            , COALESCE(F.server_instance_name, CONVERT(SYSNAME, @@SERVERNAME))
            , F.database_name
            , F.schema_name
            , F.object_name
            , CONVERT(VARCHAR(10), F.NM_ACAO)
            , F.action_id
            , F.session_id
            , F.transaction_id
            , F.statement
            , 'PENDENTE_VERIFICACAO'
            , NULL, NULL, NULL
            , F.file_name
            , F.audit_file_offset
            , F.sequence_group_id
            , F.sequence_number
            , F.ID_EVENTO_AUDIT
        FROM #FonteFinal AS F
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dbo.AuditoriaDml AS D WITH (UPDLOCK, HOLDLOCK)
            WHERE D.ID_EVENTO_AUDIT = F.ID_EVENTO_AUDIT
        );

        SET @QtdInseridos = @@ROWCOUNT;

        UPDATE dbo.AuditoriaDmlControle
        SET
              NM_AUDIT = @AuditName
            , NM_FILE_PATTERN = @FilePattern
            , DT_ULTIMA_COLETA = SYSDATETIME()
            , NR_EVENTOS_LIDOS = @QtdEventosLidos
            , NR_EVENTOS_VALIDOS = @QtdEventosValidos
            , NR_EVENTOS_INSERIDOS = @QtdInseridos
        WHERE ID = 1;

        IF @@ROWCOUNT = 0
        BEGIN
            INSERT INTO dbo.AuditoriaDmlControle
            (
                  ID, NM_AUDIT, NM_FILE_PATTERN, DT_ULTIMA_COLETA
                , NR_EVENTOS_LIDOS, NR_EVENTOS_VALIDOS, NR_EVENTOS_INSERIDOS
            )
            VALUES
            (
                  1, @AuditName, @FilePattern, SYSDATETIME()
                , @QtdEventosLidos, @QtdEventosValidos, @QtdInseridos
            );
        END;

        SELECT
              CAST(N'OK' AS VARCHAR(30)) AS ST_EXECUCAO
            , @FilePattern AS NM_FILE_PATTERN
            , @QtdEventosLidos AS NR_EVENTOS_LIDOS
            , @QtdEventosValidos AS NR_EVENTOS_VALIDOS
            , @QtdInseridos AS NR_EVENTOS_INSERIDOS;

        EXEC sys.sp_releaseapplock @Resource = @LockResource, @LockOwner = N'Session';
    END TRY
    BEGIN CATCH
        EXEC sys.sp_releaseapplock @Resource = @LockResource, @LockOwner = N'Session';
        THROW;
    END CATCH;
END;
GO
