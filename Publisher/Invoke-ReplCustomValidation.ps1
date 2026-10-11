param
(
    [Parameter(Mandatory = $true)]
    [string]$ControlServer,

    [string]$ControlDatabase = "ReplicationAudit",

    [string]$SubscriberControlDatabase = "ReplicationAudit",

    [int]$MaxItems = 20,

    [int]$MaxRetries = 3,

    [int]$RetrySeconds = 5
)


$ErrorActionPreference = "Stop"


# ============================================================
# Funções
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
        "Application Name=ReplCustomValidation;" +
        "Connect Timeout=30;"


    $Connection =
        New-Object System.Data.SqlClient.SqlConnection $ConnectionString


    return $Connection
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


    $Connection = New-SqlConnection `
        -Server $Server `
        -Database $Database


    try
    {
        $Connection.Open()


        $Command =
            New-Object System.Data.SqlClient.SqlCommand


        $Command.Connection = $Connection
        $Command.CommandText = $Query
        $Command.CommandTimeout = 0


        $Adapter =
            New-Object System.Data.SqlClient.SqlDataAdapter $Command


        $Table =
            New-Object System.Data.DataTable


        [void]$Adapter.Fill($Table)


        # Impede o PowerShell de enumerar o DataTable como DataRow.
        # Sem isso, consultas que retornam 1 linha podem perder a propriedade .Rows,
        # fazendo o worker reservar o item mas não conseguir atualizar o mesmo ID.
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


    $Connection = New-SqlConnection `
        -Server $Server `
        -Database $Database


    try
    {
        $Connection.Open()


        $Command =
            New-Object System.Data.SqlClient.SqlCommand


        $Command.Connection = $Connection
        $Command.CommandText = $Query
        $Command.CommandTimeout = 0


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


# ============================================================
# Recupera processamentos abandonados
#
# Exemplo:
# Job ou PowerShell caiu durante execução.
# ============================================================

$RecoverySQL = @"

UPDATE dbo.ReplDistDiff

SET
      ST_PROCESSAMENTO = 'PENDENTE_VALIDACAO'
    , DT_ATU = SYSDATETIME()

    , DS_MENSAGEM =
        N'Processamento anterior recuperado automaticamente pelo worker.'

WHERE
        TP_VALIDACAO IN
        (
              'CHECKSUM_CUSTOM'
            , 'CHECKSUM_NATIVO'
        )
    AND ST_PROCESSAMENTO = 'PROCESSANDO_VALIDACAO'

    AND DT_INI_PROCESSAMENTO <
        DATEADD(MINUTE, -30, SYSDATETIME());

"@


Invoke-SqlNonQuery `
    -Server $ControlServer `
    -Database $ControlDatabase `
    -Query $RecoverySQL



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
# Processamento
# ============================================================

for ($Item = 1; $Item -le $MaxItems; $Item++)
{

    # --------------------------------------------------------
    # Reserva 1 item
    # --------------------------------------------------------

    $ClaimSQL = @"

;WITH Fila AS
(
    SELECT TOP (1)
        *

    FROM dbo.ReplDistDiff WITH
    (
          UPDLOCK
        , READPAST
        , ROWLOCK
    )

    WHERE
            TP_VALIDACAO IN
            (
                  'CHECKSUM_CUSTOM'
                , 'CHECKSUM_NATIVO'
            )
        AND ST_PROCESSAMENTO = 'PENDENTE_VALIDACAO'

    ORDER BY
          DT_INC
        , ID
)

UPDATE Fila

SET
      ST_PROCESSAMENTO = 'PROCESSANDO_VALIDACAO'
    , DT_INI_PROCESSAMENTO = SYSDATETIME()
    , DT_ATU = SYSDATETIME()

    , DS_MENSAGEM =
        N'Validação ' + TP_VALIDACAO + N' em processamento.'

OUTPUT

      inserted.ID

    , inserted.NM_PUBLISHER

    , inserted.NM_DATABASE_ORIGEM
    , inserted.NM_PUBLICACAO
    , inserted.NM_ARTIGO

    , inserted.NM_SCHEMA_ORIGEM
    , inserted.NM_TABELA_ORIGEM

    , inserted.NM_SUBSCRIBER
    , inserted.NM_DATABASE_DESTINO

    , inserted.NM_SCHEMA_DESTINO
    , inserted.NM_TABELA_DESTINO

    , inserted.TP_VALIDACAO
    , inserted.DS_COLUNAS_IGNORADAS;

"@


    $Fila =
        Invoke-SqlDataTable `
            -Server $ControlServer `
            -Database $ControlDatabase `
            -Query $ClaimSQL


    if ($null -eq $Fila)
    {
        throw "A consulta de reserva da fila retornou objeto nulo."
    }


    if ($Fila.Rows.Count -eq 0)
    {
        Write-Output "Nenhuma validação CHECKSUM pendente."

        break
    }


    $Registro = $Fila.Rows[0]


    $ID =
        [long]$Registro.ID


    Write-Output "Item reservado na fila. ID=$ID"


    $Publisher =
        [string]$Registro.NM_PUBLISHER


    if ([string]::IsNullOrWhiteSpace($Publisher))
    {
        $Publisher = $ControlServer
    }


    $DatabaseOrigem =
        [string]$Registro.NM_DATABASE_ORIGEM


    $Publication =
        [string]$Registro.NM_PUBLICACAO


    $Article =
        [string]$Registro.NM_ARTIGO


    $SchemaOrigem =
        [string]$Registro.NM_SCHEMA_ORIGEM


    $TabelaOrigem =
        [string]$Registro.NM_TABELA_ORIGEM


    $Subscriber =
        [string]$Registro.NM_SUBSCRIBER


    $DatabaseDestino =
        [string]$Registro.NM_DATABASE_DESTINO


    $SchemaDestino =
        [string]$Registro.NM_SCHEMA_DESTINO


    $TabelaDestino =
        [string]$Registro.NM_TABELA_DESTINO


    $TipoValidacao =
        [string]$Registro.TP_VALIDACAO


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
    Write-Output "ID.............: $ID"
    Write-Output "Publisher......: $Publisher"
    Write-Output "Database.......: $DatabaseOrigem"
    Write-Output "Publication....: $Publication"
    Write-Output "Article........: $Article"
    Write-Output "Tipo...........: $TipoValidacao"
    Write-Output "Subscriber.....: $Subscriber"
    Write-Output "============================================================"


    try
    {

        # ----------------------------------------------------
        # Obtém somente as colunas publicadas no artigo.
        #
        # CHECKSUM_NATIVO:
        #   usa todas as colunas publicadas, pois não existem
        #   computed columns não determinísticas.
        #
        # CHECKSUM_CUSTOM:
        #   exclui somente computed columns não determinísticas.
        # ----------------------------------------------------

        $PublicationSQL =
            Quote-SqlString $Publication


        $ArticleSQL =
            Quote-SqlString $Article


        $MetadataSQL = @"

SELECT

    STRING_AGG
    (
        CONVERT
        (
            NVARCHAR(MAX),
            QUOTENAME(C.[name])
        ),
        N','
    )
    WITHIN GROUP
    (
        ORDER BY C.[column_id]
    ) AS ColumnList

FROM dbo.sysarticles AS A

INNER JOIN dbo.syspublications AS P
    ON P.[pubid] = A.[pubid]

INNER JOIN dbo.sysarticlecolumns AS AC
    ON AC.[artid] = A.[artid]

INNER JOIN sys.columns AS C
    ON C.[object_id] = A.[objid]
   AND C.[column_id] = AC.[colid]

LEFT JOIN sys.computed_columns AS CC
    ON CC.[object_id] = C.[object_id]
   AND CC.[column_id] = C.[column_id]

WHERE
        P.[name] = $PublicationSQL
    AND A.[name] = $ArticleSQL

    AND
    (
        CC.[column_id] IS NULL

        OR COLUMNPROPERTY
        (
              CC.[object_id]
            , CC.[name]
            , 'IsDeterministic'
        ) = 1
    );

"@


        $Metadata =
            Invoke-SqlDataTable `
                -Server $Publisher `
                -Database $DatabaseOrigem `
                -Query $MetadataSQL


        if (
            ($Metadata.Rows.Count -eq 0) -or
            ([DBNull]::Value.Equals($Metadata.Rows[0].ColumnList)) -or
            ([string]::IsNullOrWhiteSpace([string]$Metadata.Rows[0].ColumnList))
        )
        {
            throw "Nenhuma coluna válida foi encontrada para o artigo."
        }


        $ColumnList =
            [string]$Metadata.Rows[0].ColumnList


        Write-Output "Colunas utilizadas:"
        Write-Output $ColumnList


        # ----------------------------------------------------
        # Monta consulta de validação
        # ----------------------------------------------------

        $SourceObject =
            (Quote-SqlIdentifier $SchemaOrigem) +
            "." +
            (Quote-SqlIdentifier $TabelaOrigem)


        $DestinationObject =
            (Quote-SqlIdentifier $SchemaDestino) +
            "." +
            (Quote-SqlIdentifier $TabelaDestino)


        $SourceQuery = @"

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

FROM $SourceObject;

"@


        $DestinationQuery = @"

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

FROM $DestinationObject;

"@


        $ResultadoFinalOrigem = $null
        $ResultadoFinalDestino = $null

        $Convergente = $false


        # ----------------------------------------------------
        # Retry
        #
        # Reduz falso positivo causado por pequena latência
        # entre Publisher e Subscriber.
        # ----------------------------------------------------

        for
        (
            $Tentativa = 1;
            $Tentativa -le $MaxRetries;
            $Tentativa++
        )
        {

            Write-Output "Tentativa $Tentativa de $MaxRetries"


            $ResultadoOrigem =
                Invoke-SqlDataTable `
                    -Server $Publisher `
                    -Database $DatabaseOrigem `
                    -Query $SourceQuery


            $ResultadoDestino =
                Invoke-SqlDataTable `
                    -Server $Subscriber `
                    -Database $DatabaseDestino `
                    -Query $DestinationQuery


            $RowOrigem =
                [long]$ResultadoOrigem.Rows[0].RowCountValue


            $RowDestino =
                [long]$ResultadoDestino.Rows[0].RowCountValue


            if ([DBNull]::Value.Equals($ResultadoOrigem.Rows[0].ChecksumValue))
            {
                $ChecksumOrigem = 0
            }
            else
            {
                $ChecksumOrigem =
                    [long]$ResultadoOrigem.Rows[0].ChecksumValue
            }


            if ([DBNull]::Value.Equals($ResultadoDestino.Rows[0].ChecksumValue))
            {
                $ChecksumDestino = 0
            }
            else
            {
                $ChecksumDestino =
                    [long]$ResultadoDestino.Rows[0].ChecksumValue
            }


            Write-Output "Publisher  RowCount=$RowOrigem Checksum=$ChecksumOrigem"
            Write-Output "Subscriber RowCount=$RowDestino Checksum=$ChecksumDestino"


            $ResultadoFinalOrigem =
                @{
                    RowCount = $RowOrigem
                    Checksum = $ChecksumOrigem
                }


            $ResultadoFinalDestino =
                @{
                    RowCount = $RowDestino
                    Checksum = $ChecksumDestino
                }


            if (
                ($RowOrigem -eq $RowDestino) -and
                ($ChecksumOrigem -eq $ChecksumDestino)
            )
            {
                $Convergente = $true

                break
            }


            if ($Tentativa -lt $MaxRetries)
            {
                Start-Sleep -Seconds $RetrySeconds
            }

        }


        # ----------------------------------------------------
        # Igual
        #
        # Não existe divergência.
        #
        # Remove da fila ReplDistDiff.
        # ----------------------------------------------------

        if ($Convergente)
        {

            Set-AuditoriaDmlStatus `
                -Subscriber $Subscriber `
                -ReplDistDiffId $ID `
                -Status "OK" `
                -Message "Validacao concluida sem divergencia."

            $FinishSQL = @"

DELETE
FROM dbo.ReplDistDiff
WHERE
        ID = $ID
    AND ST_PROCESSAMENTO = 'PROCESSANDO_VALIDACAO';

"@


            Invoke-SqlNonQuery `
                -Server $ControlServer `
                -Database $ControlDatabase `
                -Query $FinishSQL


            Write-Output "Resultado: SEM DIVERGENCIA"

        }


        # ----------------------------------------------------
        # Diferente
        #
        # Mantém na ReplDistDiff e envia para correção.
        # ----------------------------------------------------

        else
        {

            $RowOrigemFinal =
                $ResultadoFinalOrigem.RowCount


            $RowDestinoFinal =
                $ResultadoFinalDestino.RowCount


            $ChecksumOrigemFinal =
                $ResultadoFinalOrigem.Checksum


            $ChecksumDestinoFinal =
                $ResultadoFinalDestino.Checksum


            $FinishSQL = @"

UPDATE dbo.ReplDistDiff

SET
      DT_ATU = SYSDATETIME()
    , DT_FIM_PROCESSAMENTO = SYSDATETIME()

    , NR_ROWCOUNT_ORIGEM = $RowOrigemFinal
    , NR_ROWCOUNT_DESTINO = $RowDestinoFinal

    , VL_CHECKSUM_ORIGEM = $ChecksumOrigemFinal
    , VL_CHECKSUM_DESTINO = $ChecksumDestinoFinal

    , ST_PROCESSAMENTO = 'PENDENTE_CORRECAO'

    , DS_MENSAGEM =
        N'Divergência confirmada pelo $TipoValidacao após $MaxRetries tentativa(s).'

WHERE
    ID = $ID;

"@


            Invoke-SqlNonQuery `
                -Server $ControlServer `
                -Database $ControlDatabase `
                -Query $FinishSQL

            Set-AuditoriaDmlStatus `
                -Subscriber $Subscriber `
                -ReplDistDiffId $ID `
                -Status "DIVERGENTE" `
                -Message "Divergencia confirmada. Aguardando correcao."


            Write-Output "Resultado: DIVERGENCIA"
            Write-Output "Tipo: $TipoValidacao"
            Write-Output "Status: PENDENTE_CORRECAO"

        }

    }

    catch
    {

        $Erro =
            $_.Exception.Message


        Write-Output "ERRO: $Erro"


        $ErroSQL =
            Quote-SqlString $Erro


        $ErrorUpdateSQL = @"

UPDATE dbo.ReplDistDiff

SET
      DT_ATU = SYSDATETIME()
    , DT_FIM_PROCESSAMENTO = SYSDATETIME()

    , ST_PROCESSAMENTO = 'ERRO_VALIDACAO'

    , DS_MENSAGEM = $ErroSQL

WHERE
    ID = $ID;

"@


        Invoke-SqlNonQuery `
            -Server $ControlServer `
            -Database $ControlDatabase `
            -Query $ErrorUpdateSQL

        try
        {
            Set-AuditoriaDmlStatus `
                -Subscriber $Subscriber `
                -ReplDistDiffId $ID `
                -Status "ERRO_VALIDACAO" `
                -Message $Erro
        }
        catch
        {
            Write-Output "Falha ao atualizar AuditoriaDml: $($_.Exception.Message)"
        }

    }

}


Write-Output ""
Write-Output "Processamento finalizado."
