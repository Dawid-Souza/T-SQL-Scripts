USE [{{CONTROL_DATABASE}}];
GO

IF OBJECT_ID(N'dbo.ReplAuditTargetDatabase', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReplAuditTargetDatabase
    (
          NM_DATABASE SYSNAME NOT NULL
        , IC_ATIVO BIT NOT NULL
            CONSTRAINT DF_ReplAuditTargetDatabase_IC_ATIVO DEFAULT (1)
        , CONSTRAINT PK_ReplAuditTargetDatabase PRIMARY KEY CLUSTERED (NM_DATABASE)
    );
END;
GO
