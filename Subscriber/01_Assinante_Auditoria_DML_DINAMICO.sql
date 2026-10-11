/*
    Cria um Server Audit por instancia e uma Database Audit Specification
    para cada banco informado em configuracao.json.

    Tokens entre {{...}} sao preenchidos por Start-Replicacao.ps1.
*/
USE [master];
GO

DECLARE
      @AuditPath NVARCHAR(260) = {{AUDIT_PATH_LITERAL}}
    , @SQLPath NVARCHAR(260)
    , @SQL NVARCHAR(MAX)
    , @DirectoryExists BIT = 0;

IF NULLIF(LTRIM(RTRIM(@AuditPath)), N'') IS NULL
BEGIN
    EXEC master.dbo.xp_instance_regread
          N'HKEY_LOCAL_MACHINE'
        , N'Software\Microsoft\MSSQLServer\Setup'
        , N'SQLPath'
        , @SQLPath OUTPUT;

    IF NULLIF(LTRIM(RTRIM(@SQLPath)), N'') IS NULL
        THROW 50000, 'Nao foi possivel identificar o SQLPath da instancia.', 1;

    SET @SQLPath =
        CASE WHEN RIGHT(@SQLPath, 1) IN (N'\', N'/')
             THEN LEFT(@SQLPath, LEN(@SQLPath) - 1)
             ELSE @SQLPath END;

    SET @AuditPath = @SQLPath + N'\Audit\';
END;

IF RIGHT(@AuditPath, 1) NOT IN (N'\', N'/')
    SET @AuditPath += N'\';

DECLARE @FileExist TABLE
(
      FileExists INT
    , FileIsADirectory INT
    , ParentDirectoryExists INT
);

INSERT INTO @FileExist
EXEC master.dbo.xp_fileexist @AuditPath;

SELECT @DirectoryExists = CONVERT(BIT, ISNULL(MAX(FileIsADirectory), 0))
FROM @FileExist;

IF @DirectoryExists = 0
BEGIN
    BEGIN TRY
        EXEC master.dbo.xp_create_subdir @AuditPath;
    END TRY
    BEGIN CATCH
        DECLARE @PathError NVARCHAR(2048) =
            N'Falha ao criar o diretorio de auditoria ' + @AuditPath
            + N'. ' + ERROR_MESSAGE();
        THROW 50001, @PathError, 1;
    END CATCH;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.server_audits
    WHERE [name] = N'{{AUDIT_NAME_STRING}}'
)
BEGIN
    SET @SQL = N'
CREATE SERVER AUDIT {{AUDIT_NAME_IDENTIFIER}}
TO FILE
(
      FILEPATH = N''' + REPLACE(@AuditPath, N'''', N'''''') + N'''
    , MAXSIZE = {{AUDIT_MAX_SIZE_MB}} MB
    , MAX_ROLLOVER_FILES = {{AUDIT_MAX_ROLLOVER_FILES}}
    , RESERVE_DISK_SPACE = OFF
)
WITH
(
      QUEUE_DELAY = 1000
    , ON_FAILURE = CONTINUE
);';

    EXEC sys.sp_executesql @SQL;
END;

SET @SQL = N'ALTER SERVER AUDIT {{AUDIT_NAME_IDENTIFIER}} WITH (STATE = ON);';
EXEC sys.sp_executesql @SQL;

RAISERROR('Diretorio da auditoria DML: %s', 10, 1, @AuditPath) WITH NOWAIT;
GO

DECLARE @Databases TABLE
(
    NM_DATABASE SYSNAME NOT NULL PRIMARY KEY
);

INSERT INTO @Databases (NM_DATABASE)
VALUES
{{DATABASE_VALUES}};

DECLARE
      @Database SYSNAME
    , @SQL NVARCHAR(MAX);

DECLARE DatabaseCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT NM_DATABASE
    FROM @Databases
    ORDER BY NM_DATABASE;

OPEN DatabaseCursor;
FETCH NEXT FROM DatabaseCursor INTO @Database;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF DB_ID(@Database) IS NULL
    BEGIN
        DECLARE @DatabaseError NVARCHAR(2048) =
            N'Banco configurado nao encontrado no Subscriber: ' + @Database;
        CLOSE DatabaseCursor;
        DEALLOCATE DatabaseCursor;
        THROW 50002, @DatabaseError, 1;
    END;

    SET @SQL = N'
USE ' + QUOTENAME(@Database) + N';

IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_audit_specifications
    WHERE [name] = N''{{AUDIT_SPEC_NAME_STRING}}''
)
BEGIN
    CREATE DATABASE AUDIT SPECIFICATION {{AUDIT_SPEC_NAME_IDENTIFIER}}
    FOR SERVER AUDIT {{AUDIT_NAME_IDENTIFIER}}
    ADD
    (
        INSERT, UPDATE, DELETE
        ON DATABASE::' + QUOTENAME(@Database) + N'
        BY [public]
    )
    WITH (STATE = ON);
END
ELSE
BEGIN
    ALTER DATABASE AUDIT SPECIFICATION {{AUDIT_SPEC_NAME_IDENTIFIER}}
    WITH (STATE = ON);
END;';

    EXEC sys.sp_executesql @SQL;

    FETCH NEXT FROM DatabaseCursor INTO @Database;
END;

CLOSE DatabaseCursor;
DEALLOCATE DatabaseCursor;
GO

SELECT
      A.[name] AS NM_AUDIT
    , A.[is_state_enabled]
    , A.[type_desc]
    , A.[on_failure_desc]
FROM sys.server_audits AS A
WHERE A.[name] = N'{{AUDIT_NAME_STRING}}';
GO
