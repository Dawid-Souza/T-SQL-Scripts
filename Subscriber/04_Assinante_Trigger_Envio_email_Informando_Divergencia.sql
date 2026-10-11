USE [{{SUBSCRIBER_CONTROL_DATABASE}}];
GO

CREATE OR ALTER TRIGGER dbo.TR_AuditoriaDml_Email
ON dbo.AuditoriaDml
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
          @Enabled BIT = 0
        , @Profile SYSNAME
        , @Recipients NVARCHAR(2048)
        , @Subject NVARCHAR(255)
        , @Body NVARCHAR(MAX);

    SELECT @Enabled = TRY_CONVERT(BIT, VL_VALOR)
    FROM dbo.ReplAuditSettings
    WHERE NM_CHAVE = N'EmailEnabled';

    IF ISNULL(@Enabled, 0) = 0
        RETURN;

    SELECT @Profile = NULLIF(LTRIM(RTRIM(VL_VALOR)), N'')
    FROM dbo.ReplAuditSettings
    WHERE NM_CHAVE = N'DatabaseMailProfile';

    SELECT @Recipients = NULLIF(LTRIM(RTRIM(VL_VALOR)), N'')
    FROM dbo.ReplAuditSettings
    WHERE NM_CHAVE = N'EmailRecipients';

    IF @Profile IS NULL OR @Recipients IS NULL
        RETURN;

    IF NOT EXISTS
    (
        SELECT 1
        FROM inserted AS I
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dbo.ReplAuditExcludedPrincipal AS P
            WHERE P.IC_ATIVO = 1
              AND P.NM_PRINCIPAL = ISNULL(I.NM_USUARIO, N'')
        )
    )
        RETURN;

    SET @Subject =
          N'[DBA][REPLICACAO] Alteracao detectada - '
        + CONVERT(NVARCHAR(128), @@SERVERNAME);

    SET @Body =
          N'Foi identificada alteracao de dados em banco Subscriber.'
        + CHAR(13) + CHAR(10)
        + N'Servidor: ' + CONVERT(NVARCHAR(128), @@SERVERNAME)
        + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10);

    SELECT @Body = @Body
        + N'------------------------------------------------------------'
        + CHAR(13) + CHAR(10)
        + N'Data........: ' + CONVERT(NVARCHAR(30), I.DT_EVENTO, 121) + CHAR(13) + CHAR(10)
        + N'Banco.......: ' + ISNULL(I.NM_DATABASE, N'') + CHAR(13) + CHAR(10)
        + N'Schema......: ' + ISNULL(I.NM_SCHEMA, N'') + CHAR(13) + CHAR(10)
        + N'Objeto......: ' + ISNULL(I.NM_OBJETO, N'') + CHAR(13) + CHAR(10)
        + N'Operacao....: ' + ISNULL(I.TP_OPERACAO, N'') + CHAR(13) + CHAR(10)
        + N'Usuario.....: ' + ISNULL(I.NM_USUARIO, N'') + CHAR(13) + CHAR(10)
        + N'Host........: ' + ISNULL(I.NM_HOST, N'') + CHAR(13) + CHAR(10)
        + N'Aplicacao...: ' + ISNULL(I.NM_APLICACAO, N'') + CHAR(13) + CHAR(10)
        + N'Comando.....: ' + ISNULL(I.DS_COMANDO, N'')
        + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10)
    FROM inserted AS I
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM dbo.ReplAuditExcludedPrincipal AS P
        WHERE P.IC_ATIVO = 1
          AND P.NM_PRINCIPAL = ISNULL(I.NM_USUARIO, N'')
    );

    EXEC msdb.dbo.sp_send_dbmail
          @profile_name = @Profile
        , @recipients = @Recipients
        , @subject = @Subject
        , @body = @Body
        , @body_format = 'TEXT';
END;
GO
