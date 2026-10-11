USE [{{CONTROL_DATABASE}}];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.ReplHisDistDiff', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReplHisDistDiff
    (
          ID_LOG                      BIGINT IDENTITY(1,1) NOT NULL
        , ID_DIST_DIFF                BIGINT NOT NULL
        , DT_LOG                      DATETIME2(3) NOT NULL
            CONSTRAINT DF_ReplHisDistDiff_DT_LOG DEFAULT (SYSDATETIME())
        , DT_INC                      DATETIME2(3) NULL
        , DT_ATU                      DATETIME2(3) NULL
        , NM_PUBLISHER                SYSNAME NULL
        , NM_DATABASE_ORIGEM          SYSNAME NULL
        , NM_PUBLICACAO               SYSNAME NULL
        , NM_ARTIGO                   SYSNAME NULL
        , NM_SCHEMA_ORIGEM            SYSNAME NULL
        , NM_TABELA_ORIGEM            SYSNAME NULL
        , NM_SUBSCRIBER               SYSNAME NULL
        , NM_DATABASE_DESTINO         SYSNAME NULL
        , NM_SCHEMA_DESTINO           SYSNAME NULL
        , NM_TABELA_DESTINO           SYSNAME NULL
        , TP_VALIDACAO                VARCHAR(30) NULL
        , IC_COMPUTED_NDET            BIT NULL
        , DS_COLUNAS_IGNORADAS        NVARCHAR(MAX) NULL
        , NR_ROWCOUNT_ORIGEM          BIGINT NULL
        , NR_ROWCOUNT_DESTINO         BIGINT NULL
        , VL_CHECKSUM_ORIGEM          BIGINT NULL
        , VL_CHECKSUM_DESTINO         BIGINT NULL
        , NR_ERRO_REPL                INT NULL
        , DS_ERRO_REPL                NVARCHAR(4000) NULL
        , ST_FINAL                    VARCHAR(30) NULL
        , DT_INI_PROCESSAMENTO        DATETIME2(3) NULL
        , DT_FIM_PROCESSAMENTO        DATETIME2(3) NULL
        , DS_ARQUIVO_CORRECAO         NVARCHAR(2000) NULL
        , DS_COMANDO_TABLEDIFF        NVARCHAR(MAX) NULL
        , NR_RETORNO_TABLEDIFF        INT NULL
        , DS_MENSAGEM                 NVARCHAR(MAX) NULL
        , DT_REVALIDACAO              DATETIME2(3) NULL
        , ST_REVALIDACAO              VARCHAR(30) NULL
        , CONSTRAINT PK_ReplHisDistDiff PRIMARY KEY CLUSTERED (ID_LOG)
    );

    CREATE INDEX IX_ReplHisDistDiff_Origem
        ON dbo.ReplHisDistDiff (ID_DIST_DIFF, DT_LOG);
END;
GO
