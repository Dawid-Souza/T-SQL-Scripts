param
(
    [Parameter(Mandatory = $true)]
    [string]$ControlServer,

    [string]$ControlDatabase = "ReplicationAudit",

    [string]$SubscriberControlDatabase = "ReplicationAudit",

    [int]$MaxItems = 5,

    [int]$CommandTimeout = 600
)

$ErrorActionPreference = "Stop"


# ============================================================
# SQL helpers
# ============================================================

function New-SqlConnection
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [string]$Database
    )

    $ConnectionString =
        "Server=$Server;" +
        "Database=$Database;" +
        "Integrated Security=SSPI;" +
        "Application Name=ReplCustomCorrection;" +
        "Connect Timeout=30;"

    return (New-Object System.Data.SqlClient.SqlConnection $ConnectionString)
}


function Invoke-SqlDataTable
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [string]$Database,

        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $Connection = New-SqlConnection -Server $Server -Database $Database

    try
    {
        $Connection.Open()

        $Command = $Connection.CreateCommand()
        $Command.CommandText = $Query
        $Command.CommandTimeout = $CommandTimeout

        $Adapter = New-Object System.Data.SqlClient.SqlDataAdapter $Command
        $Table = New-Object System.Data.DataTable

        [void]$Adapter.Fill($Table)

        # Evita enumeração automática do DataTable pelo PowerShell.
        return ,$Table
    }
    finally
    {
        if ($Connection.State -ne "Closed")
        {
            $Connection.Close()
        }

        $Connection.Dispose()
    }
}


function Invoke-SqlNonQuery
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [string]$Database,

        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $Connection = New-SqlConnection -Server $Server -Database $Database

    try
    {
        $Connection.Open()

        $Command = $Connection.CreateCommand()
        $Command.CommandText = $Query
        $Command.CommandTimeout = $CommandTimeout

        [void]$Command.ExecuteNonQuery()
    }
    finally
    {
        if ($Connection.State -ne "Closed")
        {
            $Connection.Close()
        }

        $Connection.Dispose()
    }
}


function Invoke-SqlParameterizedNonQuery
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [string]$Database,

        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters
    )

    $Connection = New-SqlConnection -Server $Server -Database $Database

    try
    {
        $Connection.Open()

        $Command = $Connection.CreateCommand()
        $Command.CommandText = $Query
        $Command.CommandTimeout = $CommandTimeout

        foreach ($Name in $Parameters.Keys)
        {
            $Value = $Parameters[$Name]

            $Parameter = $Command.Parameters.AddWithValue(
                $Name,
                $(if ($null -eq $Value -or $Value -is [System.DBNull]) { [DBNull]::Value } else { $Value })
            )

            [void]$Parameter
        }

        return $Command.ExecuteNonQuery()
    }
    finally
    {
        if ($Connection.State -ne "Closed")
        {
            $Connection.Close()
        }

        $Connection.Dispose()
    }
}


function Quote-SqlIdentifier
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return "[" + $Value.Replace("]", "]]") + "]"
}


function Quote-SqlString
{
    param
    (
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value)
    {
        return "NULL"
    }

    return "N'" + $Value.Replace("'", "''") + "'"
}



function Set-AuditoriaDmlStatus
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Subscriber,

        [Parameter(Mandatory = $true)]
        [long]$ReplDistDiffId,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $StatusSql = Quote-SqlString $Status
    $MessageSql = Quote-SqlString $Message

    $Sql = @"

UPDATE dbo.AuditoriaDml
SET
      ST_PROCESSAMENTO = $StatusSql
    , DT_PROCESSAMENTO = SYSDATETIME()
    , DS_MENSAGEM = $MessageSql
WHERE
    ID_REPL_DIST_DIFF = $ReplDistDiffId;

"@

    Invoke-SqlNonQuery `
        -Server $Subscriber `
        -Database $SubscriberControlDatabase `
        -Query $Sql
}


# ============================================================
# Value / key helpers
# ============================================================

function ConvertTo-KeyPart
{
    param
    (
        $Value
    )

    if ($null -eq $Value -or $Value -is [System.DBNull])
    {
        return "<NULL>"
    }

    if ($Value -is [byte[]])
    {
        return "B:" + [Convert]::ToBase64String($Value)
    }

    if ($Value -is [DateTime])
    {
        return "D:" + $Value.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [DateTimeOffset])
    {
        return "DO:" + $Value.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [IFormattable])
    {
        $Text = $Value.ToString($null, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    else
    {
        $Text = [string]$Value
    }

    $Bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return "V:" + [Convert]::ToBase64String($Bytes)
}


function Get-RowKey
{
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Data.DataRow]$Row,

        [Parameter(Mandatory = $true)]
        [string[]]$KeyColumns
    )

    $Parts = New-Object System.Collections.Generic.List[string]

    foreach ($Column in $KeyColumns)
    {
        $Parts.Add((ConvertTo-KeyPart $Row[$Column]))
    }

    return ($Parts -join "|")
}


function Test-ValueEqual
{
    param
    (
        $Left,
        $Right
    )

    $LeftNull  = ($null -eq $Left  -or $Left  -is [System.DBNull])
    $RightNull = ($null -eq $Right -or $Right -is [System.DBNull])

    if ($LeftNull -and $RightNull)
    {
        return $true
    }

    if ($LeftNull -or $RightNull)
    {
        return $false
    }

    if (($Left -is [byte[]]) -and ($Right -is [byte[]]))
    {
        if ($Left.Length -ne $Right.Length)
        {
            return $false
        }

        for ($i = 0; $i -lt $Left.Length; $i++)
        {
            if ($Left[$i] -ne $Right[$i])
            {
                return $false
            }
        }

        return $true
    }

    return $Left.Equals($Right)
}


# ============================================================
# Metadata
# ============================================================

function Get-ArticleMetadata
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Publisher,

        [Parameter(Mandatory = $true)]
        [string]$Database,

        [Parameter(Mandatory = $true)]
        [string]$Publication,

        [Parameter(Mandatory = $true)]
        [string]$Article
    )

    $PublicationSql = Quote-SqlString $Publication
    $ArticleSql = Quote-SqlString $Article

    $Query = @"

;WITH Artigo AS
(
    SELECT
          A.[artid]
        , A.[objid]
    FROM dbo.sysarticles AS A
    INNER JOIN dbo.syspublications AS P
        ON P.[pubid] = A.[pubid]
    WHERE
            P.[name] = $PublicationSql
        AND A.[name] = $ArticleSql
),
PK AS
(
    SELECT
          IC.[object_id]
        , IC.[column_id]
        , IC.[key_ordinal]
    FROM Artigo AS A
    INNER JOIN sys.indexes AS I
        ON I.[object_id] = A.[objid]
       AND I.[is_primary_key] = 1
    INNER JOIN sys.index_columns AS IC
        ON IC.[object_id] = I.[object_id]
       AND IC.[index_id] = I.[index_id]
)
SELECT
      C.[column_id]
    , C.[name] AS ColumnName

    , CONVERT(bit, CASE WHEN PK.[column_id] IS NULL THEN 0 ELSE 1 END) AS IsPrimaryKey
    , ISNULL(PK.[key_ordinal], 0) AS KeyOrdinal

    , C.[is_identity] AS IsIdentity
    , C.[is_computed] AS IsComputed

    , CONVERT
      (
          bit,
          CASE
              WHEN CC.[column_id] IS NOT NULL
               AND COLUMNPROPERTY(CC.[object_id], CC.[name], 'IsDeterministic') = 0
                  THEN 1
              ELSE 0
          END
      ) AS IsNonDeterministicComputed

    , CONVERT
      (
          bit,
          CASE
              WHEN C.[system_type_id] = 189
                  THEN 1
              ELSE 0
          END
      ) AS IsRowVersion

FROM Artigo AS A

INNER JOIN dbo.sysarticlecolumns AS AC
    ON AC.[artid] = A.[artid]

INNER JOIN sys.columns AS C
    ON C.[object_id] = A.[objid]
   AND C.[column_id] = AC.[colid]

LEFT JOIN sys.computed_columns AS CC
    ON CC.[object_id] = C.[object_id]
   AND CC.[column_id] = C.[column_id]

LEFT JOIN PK
    ON PK.[object_id] = C.[object_id]
   AND PK.[column_id] = C.[column_id]

ORDER BY
    C.[column_id];

"@

    return Invoke-SqlDataTable `
        -Server $Publisher `
        -Database $Database `
        -Query $Query
}


# ============================================================
# Revalidation
# ============================================================

function Invoke-CustomChecksum
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [string]$Database,

        [Parameter(Mandatory = $true)]
        [string]$Schema,

        [Parameter(Mandatory = $true)]
        [string]$Table,

        [Parameter(Mandatory = $true)]
        [string[]]$Columns
    )

    $ObjectName = (Quote-SqlIdentifier $Schema) + "." + (Quote-SqlIdentifier $Table)
    $ColumnList = ($Columns | ForEach-Object { Quote-SqlIdentifier $_ }) -join ","

    $Query = @"

SELECT
      COUNT_BIG(*) AS RowCountValue
    , CONVERT
      (
          BIGINT,
          CHECKSUM_AGG
          (
              BINARY_CHECKSUM
              (
                  $ColumnList
              )
          )
      ) AS ChecksumValue
FROM $ObjectName;

"@

    $Result = Invoke-SqlDataTable -Server $Server -Database $Database -Query $Query

    $RowCount = [long]$Result.Rows[0].RowCountValue

    if ([DBNull]::Value.Equals($Result.Rows[0].ChecksumValue))
    {
        $Checksum = 0
    }
    else
    {
        $Checksum = [long]$Result.Rows[0].ChecksumValue
    }

    return @{
        RowCount = $RowCount
        Checksum = $Checksum
    }
}



function ConvertTo-AuditSqlValue
{
    param
    (
        $Value
    )

    if ($null -eq $Value -or $Value -is [System.DBNull])
    {
        return "NULL"
    }

    if ($Value -is [byte[]])
    {
        return "0x" + (($Value | ForEach-Object { $_.ToString("X2") }) -join "")
    }

    if ($Value -is [bool])
    {
        if ($Value) { return "1" }
        return "0"
    }

    if ($Value -is [DateTime])
    {
        return "'" + $Value.ToString("yyyy-MM-dd HH:mm:ss.fffffff", [System.Globalization.CultureInfo]::InvariantCulture) + "'"
    }

    if ($Value -is [DateTimeOffset])
    {
        return "'" + $Value.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture) + "'"
    }

    if (
        ($Value -is [byte])   -or
        ($Value -is [sbyte])  -or
        ($Value -is [int16])  -or
        ($Value -is [uint16]) -or
        ($Value -is [int32])  -or
        ($Value -is [uint32]) -or
        ($Value -is [int64])  -or
        ($Value -is [uint64]) -or
        ($Value -is [single]) -or
        ($Value -is [double]) -or
        ($Value -is [decimal])
    )
    {
        return ([Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
    }

    $StringValue = [string]$Value
    return "N'" + $StringValue.Replace("'", "''") + "'"
}


function New-ExecutedCommandAudit
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters
    )

    $Lines = New-Object System.Collections.Generic.List[string]

    $Lines.Add("-- OPERACAO: $Operation")
    $Lines.Add(($Sql.Trim()))
    $Lines.Add("")
    $Lines.Add("-- PARAMETROS:")

    $ParameterNames = @(
        $Parameters.Keys |
        Sort-Object {
            if ($_ -match '^@p(\d+)$')
            {
                [int]$Matches[1]
            }
            else
            {
                [int]::MaxValue
            }
        }, {
            [string]$_
        }
    )

    foreach ($ParameterName in $ParameterNames)
    {
        $AuditValue = ConvertTo-AuditSqlValue $Parameters[$ParameterName]
        $Lines.Add("-- $ParameterName = $AuditValue")
    }

    return ($Lines -join [Environment]::NewLine)
}


# ============================================================
# Main worker
# ============================================================


for ($Item = 1; $Item -le $MaxItems; $Item++)
{
    $ClaimQuery = @"

EXEC dbo.SpReplProcessarCorrecao
      @ID = NULL
    , @TipoValidacao = NULL;

"@

    $Fila = Invoke-SqlDataTable `
        -Server $ControlServer `
        -Database $ControlDatabase `
        -Query $ClaimQuery

    if ($null -eq $Fila -or $Fila.Rows.Count -eq 0)
    {
        Write-Output "Nenhuma correção pendente."
        break
    }

    $Registro = $Fila.Rows[0]

    $ID               = [long]$Registro.ID
    $Publisher        = [string]$Registro.NM_PUBLISHER
    $DatabaseOrigem   = [string]$Registro.NM_DATABASE_ORIGEM
    $Publication      = [string]$Registro.NM_PUBLICACAO
    $Article          = [string]$Registro.NM_ARTIGO
    $SchemaOrigem     = [string]$Registro.NM_SCHEMA_ORIGEM
    $TabelaOrigem     = [string]$Registro.NM_TABELA_ORIGEM
    $Subscriber       = [string]$Registro.NM_SUBSCRIBER
    $DatabaseDestino  = [string]$Registro.NM_DATABASE_DESTINO
    $SchemaDestino    = [string]$Registro.NM_SCHEMA_DESTINO
    $TabelaDestino    = [string]$Registro.NM_TABELA_DESTINO
    $TipoValidacao    = [string]$Registro.TP_VALIDACAO

    if ([string]::IsNullOrWhiteSpace($Publisher))
    {
        $Publisher = $ControlServer
    }

    if ([string]::IsNullOrWhiteSpace($SchemaDestino))
    {
        $SchemaDestino = $SchemaOrigem
    }

    if ([string]::IsNullOrWhiteSpace($TabelaDestino))
    {
        $TabelaDestino = $TabelaOrigem
    }

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "ID.................: $ID"
    Write-Output "Tipo...............: $TipoValidacao"
    if ($TipoValidacao -eq "CHECKSUM_NATIVO")
    {
        Write-Output "Colunas............: todas as colunas publicadas"
    }
    else
    {
        Write-Output "Colunas............: publicadas, ignorando computed nao deterministicas"
    }
    Write-Output "Publisher..........: $Publisher"
    Write-Output "Origem.............: $DatabaseOrigem.$SchemaOrigem.$TabelaOrigem"
    Write-Output "Subscriber.........: $Subscriber"
    Write-Output "Destino............: $DatabaseDestino.$SchemaDestino.$TabelaDestino"
    Write-Output "============================================================"

    if ($TipoValidacao -notin @("CHECKSUM_CUSTOM", "CHECKSUM_NATIVO"))
    {
        $Message = "Worker de correcao recebeu TP_VALIDACAO nao suportado: $TipoValidacao. O item sera devolvido para PENDENTE_CORRECAO."

        $SqlMessage = Quote-SqlString $Message

        $ReturnQuery = @"

UPDATE dbo.ReplDistDiff
SET
      ST_PROCESSAMENTO = 'PENDENTE_CORRECAO'
    , DT_ATU = SYSDATETIME()
    , DS_MENSAGEM = $SqlMessage
WHERE
    ID = $ID;

"@

        Invoke-SqlNonQuery -Server $ControlServer -Database $ControlDatabase -Query $ReturnQuery

        Write-Output $Message
        break
    }

    try
    {
        # --------------------------------------------------------
        # Metadata / PK / published columns
        # --------------------------------------------------------

        $Metadata = Get-ArticleMetadata `
            -Publisher $Publisher `
            -Database $DatabaseOrigem `
            -Publication $Publication `
            -Article $Article

        if ($null -eq $Metadata -or $Metadata.Rows.Count -eq 0)
        {
            throw "Não foi possível obter metadata do artigo."
        }

        $PrimaryKeyColumns = @(
            $Metadata.Rows |
            Where-Object { [bool]$_.IsPrimaryKey } |
            Sort-Object { [int]$_.KeyOrdinal } |
            ForEach-Object { [string]$_.ColumnName }
        )

        if ($PrimaryKeyColumns.Count -eq 0)
        {
            throw "O artigo não possui Primary Key publicada. A correção custom exige chave única."
        }

        # Conjunto de comparacao para CHECKSUM_NATIVO e CHECKSUM_CUSTOM:
        # colunas publicadas, excluindo apenas computed nao deterministica.
        $CompareColumns = @(
            $Metadata.Rows |
            Where-Object { -not [bool]$_.IsNonDeterministicComputed } |
            Sort-Object { [int]$_.column_id } |
            ForEach-Object { [string]$_.ColumnName }
        )

        # Colunas graváveis:
        # exclui computed, rowversion e identity para UPDATE.
        $InsertColumns = @(
            $Metadata.Rows |
            Where-Object {
                (-not [bool]$_.IsComputed) -and
                (-not [bool]$_.IsRowVersion)
            } |
            Sort-Object { [int]$_.column_id } |
            ForEach-Object { [string]$_.ColumnName }
        )

        $UpdateColumns = @(
            $Metadata.Rows |
            Where-Object {
                (-not [bool]$_.IsPrimaryKey) -and
                (-not [bool]$_.IsComputed) -and
                (-not [bool]$_.IsIdentity) -and
                (-not [bool]$_.IsRowVersion)
            } |
            Sort-Object { [int]$_.column_id } |
            ForEach-Object { [string]$_.ColumnName }
        )

        $IdentityColumns = @(
            $Metadata.Rows |
            Where-Object { [bool]$_.IsIdentity } |
            ForEach-Object { [string]$_.ColumnName }
        )

        $SelectColumns = @(
            ($PrimaryKeyColumns + $CompareColumns) |
            Select-Object -Unique
        )

        $QuotedSelectColumns =
            ($SelectColumns | ForEach-Object { Quote-SqlIdentifier $_ }) -join ","

        $SourceObject =
            (Quote-SqlIdentifier $SchemaOrigem) + "." +
            (Quote-SqlIdentifier $TabelaOrigem)

        $DestinationObject =
            (Quote-SqlIdentifier $SchemaDestino) + "." +
            (Quote-SqlIdentifier $TabelaDestino)

        $SourceQuery = "SELECT $QuotedSelectColumns FROM $SourceObject;"
        $DestinationQuery = "SELECT $QuotedSelectColumns FROM $DestinationObject;"

        Write-Output "Lendo dados do Publisher..."
        $SourceData = Invoke-SqlDataTable `
            -Server $Publisher `
            -Database $DatabaseOrigem `
            -Query $SourceQuery

        Write-Output "Lendo dados do Subscriber..."
        $DestinationData = Invoke-SqlDataTable `
            -Server $Subscriber `
            -Database $DatabaseDestino `
            -Query $DestinationQuery

        Write-Output "Publisher Rows=$($SourceData.Rows.Count)"
        Write-Output "Subscriber Rows=$($DestinationData.Rows.Count)"

        # --------------------------------------------------------
        # Build maps by PK
        # --------------------------------------------------------

        $SourceMap = @{}
        foreach ($Row in $SourceData.Rows)
        {
            $Key = Get-RowKey -Row $Row -KeyColumns $PrimaryKeyColumns

            if ($SourceMap.ContainsKey($Key))
            {
                throw "Chave duplicada detectada no Publisher durante correção custom."
            }

            $SourceMap[$Key] = $Row
        }

        $DestinationMap = @{}
        foreach ($Row in $DestinationData.Rows)
        {
            $Key = Get-RowKey -Row $Row -KeyColumns $PrimaryKeyColumns

            if ($DestinationMap.ContainsKey($Key))
            {
                throw "Chave duplicada detectada no Subscriber durante correção custom."
            }

            $DestinationMap[$Key] = $Row
        }

        $InsertCount = 0
        $UpdateCount = 0
        $DeleteCount = 0

        # Auditoria somente das operações SQL efetivamente executadas.
        # O contexto de origem/destino já existe nas demais colunas de controle.
        $ExecutedCommands = New-Object System.Collections.Generic.List[string]

        # --------------------------------------------------------
        # INSERT / UPDATE
        # --------------------------------------------------------

        foreach ($Key in $SourceMap.Keys)
        {
            $SourceRow = $SourceMap[$Key]

            if (-not $DestinationMap.ContainsKey($Key))
            {
                $ColumnSql = ($InsertColumns | ForEach-Object { Quote-SqlIdentifier $_ }) -join ","
                $ParamNames = New-Object System.Collections.Generic.List[string]
                $Parameters = @{}

                for ($i = 0; $i -lt $InsertColumns.Count; $i++)
                {
                    $Column = $InsertColumns[$i]
                    $Param = "@p$i"

                    $ParamNames.Add($Param)
                    $Parameters[$Param] = $SourceRow[$Column]
                }

                $ValuesSql = $ParamNames -join ","

                $InsertSql = @"

INSERT INTO $DestinationObject
(
    $ColumnSql
)
VALUES
(
    $ValuesSql
);

"@

                if ($IdentityColumns.Count -gt 0)
                {
                    $InsertSql =
                        "SET IDENTITY_INSERT $DestinationObject ON;" +
                        [Environment]::NewLine +
                        $InsertSql +
                        [Environment]::NewLine +
                        "SET IDENTITY_INSERT $DestinationObject OFF;"
                }

                [void](Invoke-SqlParameterizedNonQuery `
                    -Server $Subscriber `
                    -Database $DatabaseDestino `
                    -Query $InsertSql `
                    -Parameters $Parameters)

                $AuditEntry = New-ExecutedCommandAudit `
                    -Operation "INSERT" `
                    -Sql $InsertSql `
                    -Parameters $Parameters

                $ExecutedCommands.Add($AuditEntry)

                $InsertCount++
                continue
            }

            $DestinationRow = $DestinationMap[$Key]
            $ChangedColumns = New-Object System.Collections.Generic.List[string]

            foreach ($Column in $UpdateColumns)
            {
                if (-not (Test-ValueEqual $SourceRow[$Column] $DestinationRow[$Column]))
                {
                    $ChangedColumns.Add($Column)
                }
            }

            if ($ChangedColumns.Count -gt 0)
            {
                $SetParts = New-Object System.Collections.Generic.List[string]
                $WhereParts = New-Object System.Collections.Generic.List[string]
                $Parameters = @{}

                $ParameterIndex = 0

                foreach ($Column in $ChangedColumns)
                {
                    $Param = "@p$ParameterIndex"
                    $ParameterIndex++

                    $SetParts.Add(
                        (Quote-SqlIdentifier $Column) + " = " + $Param
                    )

                    $Parameters[$Param] = $SourceRow[$Column]
                }

                foreach ($Column in $PrimaryKeyColumns)
                {
                    $Param = "@p$ParameterIndex"
                    $ParameterIndex++

                    $WhereParts.Add(
                        (Quote-SqlIdentifier $Column) + " = " + $Param
                    )

                    $Parameters[$Param] = $SourceRow[$Column]
                }

                $UpdateSql =
                    "UPDATE $DestinationObject SET " +
                    ($SetParts -join ", ") +
                    " WHERE " +
                    ($WhereParts -join " AND ") +
                    ";"

                [void](Invoke-SqlParameterizedNonQuery `
                    -Server $Subscriber `
                    -Database $DatabaseDestino `
                    -Query $UpdateSql `
                    -Parameters $Parameters)

                $AuditEntry = New-ExecutedCommandAudit `
                    -Operation "UPDATE" `
                    -Sql $UpdateSql `
                    -Parameters $Parameters

                $ExecutedCommands.Add($AuditEntry)

                $UpdateCount++
            }
        }

        # --------------------------------------------------------
        # DELETE
        # --------------------------------------------------------

        foreach ($Key in $DestinationMap.Keys)
        {
            if ($SourceMap.ContainsKey($Key))
            {
                continue
            }

            $DestinationRow = $DestinationMap[$Key]

            $WhereParts = New-Object System.Collections.Generic.List[string]
            $Parameters = @{}

            for ($i = 0; $i -lt $PrimaryKeyColumns.Count; $i++)
            {
                $Column = $PrimaryKeyColumns[$i]
                $Param = "@p$i"

                $WhereParts.Add(
                    (Quote-SqlIdentifier $Column) + " = " + $Param
                )

                $Parameters[$Param] = $DestinationRow[$Column]
            }

            $DeleteSql =
                "DELETE FROM $DestinationObject WHERE " +
                ($WhereParts -join " AND ") +
                ";"

            [void](Invoke-SqlParameterizedNonQuery `
                -Server $Subscriber `
                -Database $DatabaseDestino `
                -Query $DeleteSql `
                -Parameters $Parameters)

            $AuditEntry = New-ExecutedCommandAudit `
                -Operation "DELETE" `
                -Sql $DeleteSql `
                -Parameters $Parameters

            $ExecutedCommands.Add($AuditEntry)

            $DeleteCount++
        }

        Write-Output "Correção aplicada."
        Write-Output "INSERT=$InsertCount UPDATE=$UpdateCount DELETE=$DeleteCount"

        # --------------------------------------------------------
        # Vai para revalidação
        # --------------------------------------------------------

        $CorrectionMessage =
            "Correcao $TipoValidacao aplicada. INSERT=$InsertCount UPDATE=$UpdateCount DELETE=$DeleteCount."

        # DS_COMANDO_TABLEDIFF e reutilizado pelo worker de correcao
        # para guardar somente a operacao SQL aplicada e seus parametros.
        if ($ExecutedCommands.Count -gt 0)
        {
            $CommandHistory =
                $ExecutedCommands -join (
                    [Environment]::NewLine +
                    [Environment]::NewLine
                )
        }
        else
        {
            $CommandHistory = "NENHUMA OPERACAO NECESSARIA."
        }

        $PendingRevalidationSql = @"

UPDATE dbo.ReplDistDiff
SET
      ST_PROCESSAMENTO = 'PENDENTE_REVALIDACAO'
    , DT_ATU = SYSDATETIME()
    , DT_FIM_PROCESSAMENTO = SYSDATETIME()
    , DS_COMANDO_TABLEDIFF = @ComandoCorrecao
    , NR_RETORNO_TABLEDIFF = 0
    , DS_MENSAGEM = @Mensagem
WHERE
        ID = @ID
    AND ST_PROCESSAMENTO = 'PROCESSANDO_CORRECAO';

"@

        $PendingRevalidationParameters = @{
            "@ComandoCorrecao" = $CommandHistory
            "@Mensagem" = $CorrectionMessage
            "@ID" = $ID
        }

        [void](Invoke-SqlParameterizedNonQuery `
            -Server $ControlServer `
            -Database $ControlDatabase `
            -Query $PendingRevalidationSql `
            -Parameters $PendingRevalidationParameters)

        # --------------------------------------------------------
        # Reserva revalidação no mesmo worker
        # --------------------------------------------------------

        $ProcessingRevalidationSql = @"

UPDATE dbo.ReplDistDiff
SET
      ST_PROCESSAMENTO = 'PROCESSANDO_REVALIDACAO'
    , DT_ATU = SYSDATETIME()
    , DT_REVALIDACAO = SYSDATETIME()
    , ST_REVALIDACAO = 'PROCESSANDO'
    , DS_MENSAGEM = N'Revalidacao $TipoValidacao em processamento.'
WHERE
        ID = $ID
    AND ST_PROCESSAMENTO = 'PENDENTE_REVALIDACAO';

"@

        Invoke-SqlNonQuery `
            -Server $ControlServer `
            -Database $ControlDatabase `
            -Query $ProcessingRevalidationSql

        # --------------------------------------------------------
        # Revalida com o mesmo conjunto de colunas utilizado pelo tipo de validacao
        # --------------------------------------------------------

        $SourceValidation = Invoke-CustomChecksum `
            -Server $Publisher `
            -Database $DatabaseOrigem `
            -Schema $SchemaOrigem `
            -Table $TabelaOrigem `
            -Columns $CompareColumns

        $DestinationValidation = Invoke-CustomChecksum `
            -Server $Subscriber `
            -Database $DatabaseDestino `
            -Schema $SchemaDestino `
            -Table $TabelaDestino `
            -Columns $CompareColumns

        Write-Output "Revalidacao Publisher  RowCount=$($SourceValidation.RowCount) Checksum=$($SourceValidation.Checksum)"
        Write-Output "Revalidacao Subscriber RowCount=$($DestinationValidation.RowCount) Checksum=$($DestinationValidation.Checksum)"

        $ValidationUpdateSql = @"

UPDATE dbo.ReplDistDiff
SET
      NR_ROWCOUNT_ORIGEM = $($SourceValidation.RowCount)
    , NR_ROWCOUNT_DESTINO = $($DestinationValidation.RowCount)
    , VL_CHECKSUM_ORIGEM = $($SourceValidation.Checksum)
    , VL_CHECKSUM_DESTINO = $($DestinationValidation.Checksum)
    , DT_ATU = SYSDATETIME()
WHERE
    ID = $ID;

"@

        Invoke-SqlNonQuery `
            -Server $ControlServer `
            -Database $ControlDatabase `
            -Query $ValidationUpdateSql

        if (
            ($SourceValidation.RowCount -eq $DestinationValidation.RowCount) -and
            ($SourceValidation.Checksum -eq $DestinationValidation.Checksum)
        )
        {
            $FinalMessage =
                "Correcao $TipoValidacao aplicada e revalidada com sucesso. INSERT=$InsertCount UPDATE=$UpdateCount DELETE=$DeleteCount."

            $FinalMessageSql = Quote-SqlString $FinalMessage

            $FinalizeSql = @"

EXEC dbo.SpReplFinalizarCorrecao
      @ID = $ID
    , @StatusRevalidacao = 'OK'
    , @Mensagem = $FinalMessageSql;

"@

            Invoke-SqlNonQuery `
                -Server $ControlServer `
                -Database $ControlDatabase `
                -Query $FinalizeSql

            Set-AuditoriaDmlStatus `
                -Subscriber $Subscriber `
                -ReplDistDiffId $ID `
                -Status "CORRIGIDO" `
                -Message $FinalMessage

            Write-Output "Resultado final: OK / movido para histórico."
        }
        else
        {
            $FinalMessage =
                "Correcao $TipoValidacao aplicada, porem a revalidacao ainda encontrou divergencia."

            $FinalMessageSql = Quote-SqlString $FinalMessage

            $FinalizeSql = @"

EXEC dbo.SpReplFinalizarCorrecao
      @ID = $ID
    , @StatusRevalidacao = 'DIVERGENTE'
    , @Mensagem = $FinalMessageSql;

"@

            Invoke-SqlNonQuery `
                -Server $ControlServer `
                -Database $ControlDatabase `
                -Query $FinalizeSql

            Set-AuditoriaDmlStatus `
                -Subscriber $Subscriber `
                -ReplDistDiffId $ID `
                -Status "DIVERGENTE" `
                -Message $FinalMessage

            Write-Output "Resultado final: DIVERGENTE."
        }
    }
    catch
    {
        $ErrorMessage = $_.Exception.Message

        Write-Output "ERRO: $ErrorMessage"

        $ErrorMessageSql = Quote-SqlString $ErrorMessage

        # Descobre em que fase o item ficou.
        $StatusQuery = @"

SELECT ST_PROCESSAMENTO
FROM dbo.ReplDistDiff
WHERE ID = $ID;

"@

        try
        {
            $StatusTable = Invoke-SqlDataTable `
                -Server $ControlServer `
                -Database $ControlDatabase `
                -Query $StatusQuery

            if ($StatusTable.Rows.Count -gt 0)
            {
                $CurrentStatus = [string]$StatusTable.Rows[0].ST_PROCESSAMENTO

                if ($CurrentStatus -eq "PROCESSANDO_REVALIDACAO")
                {
                    $FinalizeErrorSql = @"

EXEC dbo.SpReplFinalizarCorrecao
      @ID = $ID
    , @StatusRevalidacao = 'ERRO'
    , @Mensagem = $ErrorMessageSql;

"@

                    Invoke-SqlNonQuery `
                        -Server $ControlServer `
                        -Database $ControlDatabase `
                        -Query $FinalizeErrorSql
                }
                else
                {
                    $CorrectionErrorSql = @"

UPDATE dbo.ReplDistDiff
SET
      ST_PROCESSAMENTO = 'ERRO_CORRECAO'
    , DT_ATU = SYSDATETIME()
    , DT_FIM_PROCESSAMENTO = SYSDATETIME()
    , DS_MENSAGEM = $ErrorMessageSql
WHERE
    ID = $ID;

"@

                    Invoke-SqlNonQuery `
                        -Server $ControlServer `
                        -Database $ControlDatabase `
                        -Query $CorrectionErrorSql
                }
            }
        }
        catch
        {
            Write-Output "Falha adicional ao registrar o erro no controle: $($_.Exception.Message)"
        }

        try
        {
            Set-AuditoriaDmlStatus `
                -Subscriber $Subscriber `
                -ReplDistDiffId $ID `
                -Status "ERRO_CORRECAO" `
                -Message $ErrorMessage
        }
        catch
        {
            Write-Output "Falha ao atualizar AuditoriaDml: $($_.Exception.Message)"
        }

        throw
    }
}

Write-Output ""
Write-Output "Worker de correção finalizado."
