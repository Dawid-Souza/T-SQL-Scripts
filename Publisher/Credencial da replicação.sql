USE [msdb];
GO

DECLARE
      @ProxyName SYSNAME = N'{{PROXY_NAME_STRING}}'
    , @CredentialName SYSNAME = NULLIF(N'{{CREDENTIAL_NAME_STRING}}', N'');

IF NOT EXISTS (SELECT 1 FROM dbo.sysproxies WHERE [name] = @ProxyName)
BEGIN
    IF @CredentialName IS NULL
        THROW 50000, 'Proxy inexistente e CredentialName nao informado.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM master.sys.credentials
        WHERE [name] = @CredentialName
    )
        THROW 50001, 'A credential configurada nao existe no SQL Server.', 1;

    EXEC dbo.sp_add_proxy
          @proxy_name = @ProxyName
        , @credential_name = @CredentialName
        , @enabled = 1;
END;
ELSE
BEGIN
    EXEC dbo.sp_update_proxy
          @proxy_name = @ProxyName
        , @enabled = 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.sysproxies AS P
    INNER JOIN dbo.sysproxysubsystem AS PS ON PS.proxy_id = P.proxy_id
    INNER JOIN dbo.syssubsystems AS S ON S.subsystem_id = PS.subsystem_id
    WHERE P.[name] = @ProxyName
      AND S.subsystem = N'PowerShell'
)
BEGIN
    EXEC dbo.sp_grant_proxy_to_subsystem
          @proxy_name = @ProxyName
        , @subsystem_name = N'PowerShell';
END;
GO
