[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param
(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "configuracao.json")
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-ConfigValue
{
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object)
    {
        return $Default
    }

    $Property = $Object.PSObject.Properties[$Name]
    if ($null -eq $Property -or $null -eq $Property.Value)
    {
        return $Default
    }

    return $Property.Value
}

function Assert-Name
{
    param([string]$Value, [string]$Label)

    if ([string]::IsNullOrWhiteSpace($Value))
    {
        throw "$Label deve ser informado."
    }

    if ($Value.Length -gt 128)
    {
        throw "$Label excede 128 caracteres: $Value"
    }
}

function ConvertTo-SqlIdentifier
{
    param([string]$Value)
    return "[" + $Value.Replace("]", "]]" ) + "]"
}

function ConvertTo-SqlIdentifierContent
{
    param([string]$Value)
    return $Value.Replace("]", "]]" )
}

function ConvertTo-SqlStringContent
{
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "" }
    return $Value.Replace("'", "''")
}

function ConvertTo-SqlLiteral
{
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "NULL" }
    return "N'" + (ConvertTo-SqlStringContent $Value) + "'"
}

function ConvertTo-ValuesSql
{
    param([string[]]$Values)

    $Rows = @(
        $Values |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique |
        ForEach-Object { "        (N'" + (ConvertTo-SqlStringContent $_) + "')" }
    )

    if ($Rows.Count -eq 0)
    {
        throw "A lista usada para gerar VALUES esta vazia."
    }

    return ($Rows -join ("," + [Environment]::NewLine))
}

function Render-Template
{
    param([string]$Path, [hashtable]$Tokens)

    $Text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)

    foreach ($Key in $Tokens.Keys)
    {
        $Text = $Text.Replace("{{" + $Key + "}}", [string]$Tokens[$Key])
    }

    $Unresolved = @(
        [regex]::Matches($Text, "\{\{[A-Z0-9_]+\}\}") |
            ForEach-Object { $_.Value } |
            Sort-Object -Unique
    )

    if ($Unresolved.Count -gt 0)
    {
        throw "Tokens nao resolvidos em ${Path}: $($Unresolved -join ', ')"
    }

    return $Text
}

function New-SqlConnection
{
    param([string]$Server, [string]$Database, [bool]$Encrypt, [bool]$TrustServerCertificate)

    $Builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $Builder.DataSource = $Server
    $Builder.InitialCatalog = $Database
    $Builder.IntegratedSecurity = $true
    $Builder.ApplicationName = "ReplicationAuditInstaller"
    $Builder.ConnectTimeout = 30
    $Builder.Encrypt = $Encrypt
    $Builder.TrustServerCertificate = $TrustServerCertificate

    return (New-Object System.Data.SqlClient.SqlConnection $Builder.ConnectionString)
}

function Invoke-SqlText
{
    param
    (
        [string]$Server,
        [string]$Database,
        [string]$SqlText,
        [int]$CommandTimeout,
        [bool]$Encrypt,
        [bool]$TrustServerCertificate,
        [string]$Description
    )

    if ($WhatIfPreference)
    {
        Write-Host "[WHATIF] $Description em $Server/$Database"
        return
    }

    $Connection = New-SqlConnection $Server $Database $Encrypt $TrustServerCertificate

    try
    {
        $Connection.Open()

        $Batches = [regex]::Split($SqlText, "(?im)^\s*GO\s*(?:--.*)?\r?$")
        foreach ($Batch in $Batches)
        {
            if ([string]::IsNullOrWhiteSpace($Batch)) { continue }

            $Command = $Connection.CreateCommand()
            $Command.CommandText = $Batch
            $Command.CommandTimeout = $CommandTimeout
            [void]$Command.ExecuteNonQuery()
            $Command.Dispose()
        }
    }
    finally
    {
        if ($Connection.State -ne "Closed") { $Connection.Close() }
        $Connection.Dispose()
    }
}

function Invoke-SqlQuery
{
    param
    (
        [string]$Server,
        [string]$Database,
        [string]$SqlText,
        [int]$CommandTimeout,
        [bool]$Encrypt,
        [bool]$TrustServerCertificate
    )

    $Connection = New-SqlConnection $Server $Database $Encrypt $TrustServerCertificate

    try
    {
        $Connection.Open()
        $Command = $Connection.CreateCommand()
        $Command.CommandText = $SqlText
        $Command.CommandTimeout = $CommandTimeout
        $Adapter = New-Object System.Data.SqlClient.SqlDataAdapter $Command
        $Table = New-Object System.Data.DataTable
        [void]$Adapter.Fill($Table)
        return ,$Table
    }
    finally
    {
        if ($Connection.State -ne "Closed") { $Connection.Close() }
        $Connection.Dispose()
    }
}

function Ensure-Database
{
    param
    (
        [string]$Server,
        [string]$Database,
        [int]$CommandTimeout,
        [bool]$Encrypt,
        [bool]$TrustServerCertificate
    )

    $DatabaseLiteral = ConvertTo-SqlLiteral $Database
    $DatabaseIdentifier = ConvertTo-SqlIdentifier $Database
    $Sql = "IF DB_ID($DatabaseLiteral) IS NULL CREATE DATABASE $DatabaseIdentifier;"

    Invoke-SqlText $Server "master" $Sql $CommandTimeout $Encrypt $TrustServerCertificate `
        "Criar/verificar banco $Database"
}

function Invoke-TemplateFile
{
    param
    (
        [string]$Server,
        [string]$Database,
        [string]$Path,
        [hashtable]$Tokens,
        [int]$CommandTimeout,
        [bool]$Encrypt,
        [bool]$TrustServerCertificate
    )

    Write-Host "  -> $([System.IO.Path]::GetFileName($Path))"
    $Sql = Render-Template $Path $Tokens
    Invoke-SqlText $Server $Database $Sql $CommandTimeout $Encrypt $TrustServerCertificate `
        "Executar $([System.IO.Path]::GetFileName($Path))"
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf))
{
    throw "Arquivo de configuracao nao encontrado: $ConfigPath"
}

$ConfigFullPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$Config = Get-Content -LiteralPath $ConfigFullPath -Raw -Encoding UTF8 | ConvertFrom-Json

$ControlServer = [string](Get-ConfigValue $Config "ControlServer")
$ControlDatabase = [string](Get-ConfigValue $Config "ControlDatabase" "ReplicationAudit")
$SubscriberControlDatabase = [string](Get-ConfigValue $Config "SubscriberControlDatabase" $ControlDatabase)
$PublisherDatabases = @((Get-ConfigValue $Config "PublisherDatabases" @()) | ForEach-Object { [string]$_ })
$Subscribers = @((Get-ConfigValue $Config "Subscribers" @()))
$WorkerLogin = [string](Get-ConfigValue $Config "WorkerLogin")
$ExcludedPrincipals = @((Get-ConfigValue $Config "ExcludedPrincipals" @()) | ForEach-Object { [string]$_ })
$InstallPath = [string](Get-ConfigValue $Config "InstallPath" "C:\DBA\ReplicationAudit")

$ConnectionConfig = Get-ConfigValue $Config "Connection"
$Encrypt = [bool](Get-ConfigValue $ConnectionConfig "Encrypt" $false)
$TrustServerCertificate = [bool](Get-ConfigValue $ConnectionConfig "TrustServerCertificate" $true)
$CommandTimeout = [int](Get-ConfigValue $ConnectionConfig "CommandTimeoutSeconds" 600)

$AuditConfig = Get-ConfigValue $Config "Audit"
$AuditName = [string](Get-ConfigValue $AuditConfig "Name" "Audit_Repl_DML")
$AuditSpecName = [string](Get-ConfigValue $AuditConfig "SpecificationName" "AuditSpec_Repl_DML")
$DefaultAuditPath = [string](Get-ConfigValue $AuditConfig "Path" "")
$AuditMaxSizeMb = [int](Get-ConfigValue $AuditConfig "MaxSizeMb" 64)
$AuditMaxRolloverFiles = [int](Get-ConfigValue $AuditConfig "MaxRolloverFiles" 5)

$EmailConfig = Get-ConfigValue $Config "Email"
$EmailEnabled = [bool](Get-ConfigValue $EmailConfig "Enabled" $false)
$EmailProfile = [string](Get-ConfigValue $EmailConfig "Profile" "")
$EmailRecipients = [string](Get-ConfigValue $EmailConfig "Recipients" "")

$AgentConfig = Get-ConfigValue $Config "SqlAgent"
$ProxyName = [string](Get-ConfigValue $AgentConfig "ProxyName" "")
$CredentialName = [string](Get-ConfigValue $AgentConfig "CredentialName" "")
$JobOwner = [string](Get-ConfigValue $AgentConfig "JobOwner" "sa")
$JobsEnabled = [bool](Get-ConfigValue $AgentConfig "JobsEnabled" $true)
$SubscriberJobName = [string](Get-ConfigValue $AgentConfig "SubscriberJobName" "DBA - Replication - DML Audit Collector")
$PublisherJobName = [string](Get-ConfigValue $AgentConfig "PublisherJobName" "DBA - Replication - Custom Validation")
$CollectorInterval = [int](Get-ConfigValue $AgentConfig "CollectorIntervalMinutes" 1)
$PublisherInterval = [int](Get-ConfigValue $AgentConfig "PublisherIntervalMinutes" 1)

$Processing = Get-ConfigValue $Config "Processing"
$AutomaticCorrection = [bool](Get-ConfigValue $Processing "AutomaticCorrectionEnabled" $false)
$MaxGroups = [int](Get-ConfigValue $Processing "MaxGroupsPerRun" 100)
$MaxValidationItems = [int](Get-ConfigValue $Processing "MaxValidationItemsPerRun" 20)
$MaxCorrectionItems = [int](Get-ConfigValue $Processing "MaxCorrectionItemsPerRun" 5)
$MaxRetries = [int](Get-ConfigValue $Processing "ValidationRetries" 3)
$RetrySeconds = [int](Get-ConfigValue $Processing "RetrySeconds" 5)

Assert-Name $ControlServer "ControlServer"
Assert-Name $ControlDatabase "ControlDatabase"
Assert-Name $SubscriberControlDatabase "SubscriberControlDatabase"
Assert-Name $WorkerLogin "WorkerLogin"
Assert-Name $AuditName "Audit.Name"
Assert-Name $AuditSpecName "Audit.SpecificationName"
Assert-Name $JobOwner "SqlAgent.JobOwner"
Assert-Name $SubscriberJobName "SqlAgent.SubscriberJobName"
Assert-Name $PublisherJobName "SqlAgent.PublisherJobName"

if ($PublisherDatabases.Count -eq 0) { throw "Informe ao menos um PublisherDatabases." }
if ($Subscribers.Count -eq 0) { throw "Informe ao menos um item em Subscribers." }
if ($InstallPath.Contains("'")) { throw "InstallPath nao pode conter apostrofo." }
if ($CollectorInterval -lt 1 -or $CollectorInterval -gt 59) { throw "CollectorIntervalMinutes deve estar entre 1 e 59." }
if ($PublisherInterval -lt 1 -or $PublisherInterval -gt 59) { throw "PublisherIntervalMinutes deve estar entre 1 e 59." }
if ($AuditMaxSizeMb -lt 1 -or $AuditMaxRolloverFiles -lt 1) { throw "Limites do Audit devem ser positivos." }
if ($CommandTimeout -lt 1) { throw "Connection.CommandTimeoutSeconds deve ser positivo." }
if ($MaxGroups -lt 1 -or $MaxValidationItems -lt 1 -or $MaxCorrectionItems -lt 1) { throw "Os limites de itens por execucao devem ser positivos." }
if ($MaxRetries -lt 1 -or $RetrySeconds -lt 0) { throw "ValidationRetries deve ser positivo e RetrySeconds nao pode ser negativo." }
if ($EmailEnabled -and ([string]::IsNullOrWhiteSpace($EmailProfile) -or [string]::IsNullOrWhiteSpace($EmailRecipients)))
{
    throw "Email.Profile e Email.Recipients sao obrigatorios quando Email.Enabled=true."
}

$PublisherDir = Join-Path $PSScriptRoot "Publisher"
$SubscriberDir = Join-Path $PSScriptRoot "Subscriber"
$EffectiveExcludedPrincipals = @(
    ($ExcludedPrincipals + @($WorkerLogin)) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)
$JobsEnabledBit = if ($JobsEnabled) { "1" } else { "0" }
$EmailEnabledString = if ($EmailEnabled) { "1" } else { "0" }

$CommonPublisherTokens = @{
    CONTROL_DATABASE = ConvertTo-SqlIdentifierContent $ControlDatabase
    CONTROL_DATABASE_STRING = ConvertTo-SqlStringContent $ControlDatabase
    WORKER_LOGIN_STRING = ConvertTo-SqlStringContent $WorkerLogin
    WORKER_LOGIN_IDENTIFIER = ConvertTo-SqlIdentifier $WorkerLogin
}

Write-Host ""
Write-Host "Publisher/controle: $ControlServer"
Write-Host "Banco de controle...: $ControlDatabase"
Write-Host "Correcao automatica..: $AutomaticCorrection"

Ensure-Database $ControlServer $ControlDatabase $CommandTimeout $Encrypt $TrustServerCertificate

$PublisherScripts = @(
    "00_Publisher_Configuracao.sql",
    "Tabela [dbo].[ReplDistDiff].sql",
    "Tabela [dbo].[ReplHisDistDiff].sql",
    "Procedure [dbo].[SpReplDescobrirTopologia].sql",
    "Procedure [dbo].[SpReplValidar].sql",
    "Procedure [dbo].[SpReplProcessarCorrecao].sql",
    "Procedure [dbo].[SpReplFinalizarCorrecao].sql",
    "06_Publisher_Permissoes.sql"
)

foreach ($ScriptName in $PublisherScripts)
{
    Invoke-TemplateFile $ControlServer $ControlDatabase (Join-Path $PublisherDir $ScriptName) `
        $CommonPublisherTokens $CommandTimeout $Encrypt $TrustServerCertificate
}

$TargetValues = ConvertTo-ValuesSql $PublisherDatabases
$TargetSql = @"
DELETE FROM dbo.ReplAuditTargetDatabase;
INSERT INTO dbo.ReplAuditTargetDatabase (NM_DATABASE, IC_ATIVO)
SELECT V.NM_DATABASE, 1
FROM
(
    VALUES
$TargetValues
) AS V(NM_DATABASE);
"@
Invoke-SqlText $ControlServer $ControlDatabase $TargetSql $CommandTimeout $Encrypt $TrustServerCertificate `
    "Configurar bancos Publisher"

foreach ($SubscriberConfig in $Subscribers)
{
    $SubscriberServer = [string](Get-ConfigValue $SubscriberConfig "Server")
    $SubscriberDatabases = @((Get-ConfigValue $SubscriberConfig "Databases" $PublisherDatabases) | ForEach-Object { [string]$_ })
    $SubscriberAuditPath = [string](Get-ConfigValue $SubscriberConfig "AuditPath" $DefaultAuditPath)

    Assert-Name $SubscriberServer "Subscribers.Server"
    if ($SubscriberDatabases.Count -eq 0) { throw "Subscriber $SubscriberServer nao possui Databases." }

    Write-Host ""
    Write-Host "Subscriber: $SubscriberServer"
    Write-Host "Bancos....: $($SubscriberDatabases -join ', ')"

    Ensure-Database $SubscriberServer $SubscriberControlDatabase $CommandTimeout $Encrypt $TrustServerCertificate

    $DatabaseValues = ConvertTo-ValuesSql $SubscriberDatabases
    if ($EffectiveExcludedPrincipals.Count -gt 0)
    {
        $ExcludedValues = ConvertTo-ValuesSql $EffectiveExcludedPrincipals
        $ExcludedInsert = @"
INSERT INTO dbo.ReplAuditExcludedPrincipal (NM_PRINCIPAL, IC_ATIVO)
SELECT V.NM_PRINCIPAL, 1
FROM
(
    VALUES
$ExcludedValues
) AS V(NM_PRINCIPAL);
"@
    }
    else
    {
        $ExcludedInsert = "-- Nenhum principal excluido da coleta."
    }

    $SubscriberTokens = @{
        SUBSCRIBER_CONTROL_DATABASE = ConvertTo-SqlIdentifierContent $SubscriberControlDatabase
        SUBSCRIBER_CONTROL_DATABASE_STRING = ConvertTo-SqlStringContent $SubscriberControlDatabase
        AUDIT_NAME_STRING = ConvertTo-SqlStringContent $AuditName
        AUDIT_NAME_IDENTIFIER = ConvertTo-SqlIdentifier $AuditName
        AUDIT_SPEC_NAME_STRING = ConvertTo-SqlStringContent $AuditSpecName
        AUDIT_SPEC_NAME_IDENTIFIER = ConvertTo-SqlIdentifier $AuditSpecName
        AUDIT_PATH_LITERAL = ConvertTo-SqlLiteral $SubscriberAuditPath
        AUDIT_MAX_SIZE_MB = $AuditMaxSizeMb
        AUDIT_MAX_ROLLOVER_FILES = $AuditMaxRolloverFiles
        DATABASE_VALUES = $DatabaseValues
        EXCLUDED_PRINCIPAL_INSERT = $ExcludedInsert
        EMAIL_ENABLED_STRING = $EmailEnabledString
        EMAIL_PROFILE_STRING = ConvertTo-SqlStringContent $EmailProfile
        EMAIL_RECIPIENTS_STRING = ConvertTo-SqlStringContent $EmailRecipients
        WORKER_LOGIN_STRING = ConvertTo-SqlStringContent $WorkerLogin
        WORKER_LOGIN_IDENTIFIER = ConvertTo-SqlIdentifier $WorkerLogin
        SUBSCRIBER_JOB_NAME_STRING = ConvertTo-SqlStringContent $SubscriberJobName
        JOB_OWNER_STRING = ConvertTo-SqlStringContent $JobOwner
        JOBS_ENABLED_BIT = $JobsEnabledBit
        COLLECTOR_INTERVAL_MINUTES = $CollectorInterval
    }

    $SubscriberScripts = @(
        "01_Assinante_Auditoria_DML_DINAMICO.sql",
        "02_Assinante_AuditoriaDml_FULLSCAN_SEQUENCE_GROUP.sql",
        "04_Assinante_Trigger_Envio_email_Informando_Divergencia.sql",
        "06_Assinante_Permissoes_AuditoriaDml.sql",
        "03_Assinante_Job_Coleta_AuditoriaDml.sql"
    )

    foreach ($ScriptName in $SubscriberScripts)
    {
        Invoke-TemplateFile $SubscriberServer "master" (Join-Path $SubscriberDir $ScriptName) `
            $SubscriberTokens $CommandTimeout $Encrypt $TrustServerCertificate
    }
}

if ($WhatIfPreference)
{
    Write-Host "[WHATIF] Copiar workers para $InstallPath"
}
else
{
    if (-not (Test-Path -LiteralPath $InstallPath -PathType Container))
    {
        [void](New-Item -ItemType Directory -Path $InstallPath -Force)
    }

    Get-ChildItem -LiteralPath $PublisherDir -Filter "Invoke-*.ps1" -File |
        Copy-Item -Destination $InstallPath -Force
}

$PublisherJobTokens = @{
    CONTROL_DATABASE_STRING = ConvertTo-SqlStringContent $ControlDatabase
    SUBSCRIBER_CONTROL_DATABASE_STRING = ConvertTo-SqlStringContent $SubscriberControlDatabase
    CREDENTIAL_NAME_STRING = ConvertTo-SqlStringContent $CredentialName
    JOB_OWNER_STRING = ConvertTo-SqlStringContent $JobOwner
    JOBS_ENABLED_BIT = $JobsEnabledBit
    PUBLISHER_JOB_NAME_STRING = ConvertTo-SqlStringContent $PublisherJobName
    PUBLISHER_INTERVAL_MINUTES = $PublisherInterval
    WORKER_PATH_POWERSHELL = ConvertTo-SqlStringContent $InstallPath.TrimEnd('\')
    MAX_GROUPS = $MaxGroups
    MAX_VALIDATION_ITEMS = $MaxValidationItems
    MAX_CORRECTION_ITEMS = $MaxCorrectionItems
    MAX_RETRIES = $MaxRetries
    RETRY_SECONDS = $RetrySeconds
    COMMAND_TIMEOUT_SECONDS = $CommandTimeout
    VALIDATION_SUCCESS_ACTION = $(if ($AutomaticCorrection) { "4" } else { "1" })
    PROXY_PARAMETER = $(if ([string]::IsNullOrWhiteSpace($ProxyName)) { "-- Executa no contexto da conta do SQL Agent" } else { ", @proxy_name = N'" + (ConvertTo-SqlStringContent $ProxyName) + "'" })
}

if (-not [string]::IsNullOrWhiteSpace($ProxyName))
{
    $PublisherJobTokens.PROXY_NAME_STRING = ConvertTo-SqlStringContent $ProxyName
    Invoke-TemplateFile $ControlServer "msdb" (Join-Path $PublisherDir "Credencial da replicação.sql") `
        $PublisherJobTokens $CommandTimeout $Encrypt $TrustServerCertificate
}

Invoke-TemplateFile $ControlServer "msdb" (Join-Path $PublisherDir "Job DBA - Replication - Custom Validation.sql") `
    $PublisherJobTokens $CommandTimeout $Encrypt $TrustServerCertificate

if (-not $WhatIfPreference)
{
    $Topology = Invoke-SqlQuery $ControlServer $ControlDatabase `
        "EXEC dbo.SpReplDescobrirTopologia @RetornarResultado = 1;" `
        $CommandTimeout $Encrypt $TrustServerCertificate

    if ($Topology.Rows.Count -eq 0)
    {
        Write-Warning "Instalacao concluida, mas nenhuma topologia ativa foi encontrada para os bancos configurados."
    }
    else
    {
        Write-Host ""
        Write-Host "Topologia encontrada: $($Topology.Rows.Count) artigo(s)/assinatura(s)."
    }
}

Write-Host ""
Write-Host "Instalacao/configuracao concluida."
if (-not $AutomaticCorrection)
{
    Write-Host "A correcao automatica esta DESLIGADA; o job encerra apos a validacao."
}
