param
(
    [Parameter(Mandatory = $true)]
    [string]$ControlServer,

    [string]$ControlDatabase = "ReplicationAudit",

    [string]$SubscriberControlDatabase = "ReplicationAudit",

    [int]$MaxGroups = 100,

    [int]$CommandTimeout = 300
)

$ErrorActionPreference = "Stop"


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
        "Application Name=ReplAuditDispatch;" +
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


Write-Output "Carregando topologia de replicacao..."

$TopologyQuery = @"
EXEC dbo.SpReplDescobrirTopologia
      @Database = NULL
    , @Publication = NULL
    , @Article = NULL
    , @Subscriber = NULL
    , @RetornarResultado = 1;
"@

$Topology = Invoke-SqlDataTable `
    -Server $ControlServer `
    -Database $ControlDatabase `
    -Query $TopologyQuery


if ($null -eq $Topology -or $Topology.Rows.Count -eq 0)
{
    Write-Output "Nenhuma topologia de replicacao encontrada."
    exit 0
}


$Subscribers = @(
    $Topology.Rows |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.NM_SUBSCRIBER) -and
        ([string]$_.NM_DATABASE_DESTINO -ne "virtual")
    } |
    ForEach-Object { [string]$_.NM_SUBSCRIBER } |
    Sort-Object -Unique
)


foreach ($Subscriber in $Subscribers)
{
    Write-Output ""
    Write-Output "Subscriber: $Subscriber"

    try
    {
        $PendingQuery = @"
SELECT TOP ($MaxGroups)
      NM_DATABASE
    , NM_SCHEMA
    , NM_OBJETO
    , MAX(ID) AS ID_MAX
    , COUNT_BIG(*) AS QTD_EVENTOS
FROM dbo.AuditoriaDml WITH (READPAST)
WHERE
    ST_PROCESSAMENTO = 'PENDENTE_VERIFICACAO'
GROUP BY
      NM_DATABASE
    , NM_SCHEMA
    , NM_OBJETO
ORDER BY
    MIN(ID);
"@

        $Pending = Invoke-SqlDataTable `
            -Server $Subscriber `
            -Database $SubscriberControlDatabase `
            -Query $PendingQuery

        if ($Pending.Rows.Count -eq 0)
        {
            Write-Output "  Nenhum evento pendente."
            continue
        }


        foreach ($Group in $Pending.Rows)
        {
            $DatabaseDestino = [string]$Group.NM_DATABASE
            $SchemaDestino = [string]$Group.NM_SCHEMA
            $ObjetoDestino = [string]$Group.NM_OBJETO
            $IdMax = [long]$Group.ID_MAX
            $QtdEventos = [long]$Group.QTD_EVENTOS


            Write-Output "  $DatabaseDestino.$SchemaDestino.$ObjetoDestino - eventos=$QtdEventos"


            # --------------------------------------------------------
            # Resolve article/publication/source DB pela topologia.
            #
            # O objeto auditado e cruzado com o artigo/tabela e com
            # database de destino + subscriber.
            # --------------------------------------------------------

            $Matches = @(
                $Topology.Rows |
                Where-Object {
                    ([string]$_.NM_SUBSCRIBER -eq $Subscriber) -and
                    ([string]$_.NM_DATABASE_DESTINO -eq $DatabaseDestino) -and
                    (
                        (
                            ([string]$_.NM_TABELA_DESTINO -eq $ObjetoDestino) -and
                            (
                                [string]::IsNullOrWhiteSpace([string]$SchemaDestino) -or
                                ([string]$_.NM_SCHEMA_DESTINO -eq $SchemaDestino)
                            )
                        ) -or
                        ([string]$_.NM_ARTIGO -eq $ObjetoDestino) -or
                        ([string]$_.NM_TABELA_ORIGEM -eq $ObjetoDestino)
                    )
                }
            )


            $UniqueMappings = @(
                $Matches |
                Group-Object {
                    ([string]$_.NM_DATABASE_ORIGEM) + "|" +
                    ([string]$_.NM_PUBLICACAO) + "|" +
                    ([string]$_.NM_ARTIGO) + "|" +
                    ([string]$_.NM_SUBSCRIBER) + "|" +
                    ([string]$_.NM_DATABASE_DESTINO)
                } |
                ForEach-Object { $_.Group[0] }
            )


            if ($UniqueMappings.Count -eq 0)
            {
                $Msg = "Objeto nao localizado na topologia de replicacao."
                $MsgSql = Quote-SqlString $Msg
                $DbSql = Quote-SqlString $DatabaseDestino
                $SchemaSql = Quote-SqlString $SchemaDestino
                $ObjectSql = Quote-SqlString $ObjetoDestino

                $UpdateSql = @"
UPDATE dbo.AuditoriaDml
SET
      ST_PROCESSAMENTO = 'NAO_PUBLICADO'
    , DT_PROCESSAMENTO = SYSDATETIME()
    , DS_MENSAGEM = $MsgSql
WHERE
        ST_PROCESSAMENTO = 'PENDENTE_VERIFICACAO'
    AND ID <= $IdMax
    AND NM_DATABASE = $DbSql
    AND ISNULL(NM_SCHEMA, N'') = ISNULL($SchemaSql, N'')
    AND NM_OBJETO = $ObjectSql;
"@

                Invoke-SqlNonQuery -Server $Subscriber -Database $SubscriberControlDatabase -Query $UpdateSql
                Write-Output "    NAO_PUBLICADO"
                continue
            }


            if ($UniqueMappings.Count -gt 1)
            {
                $Msg = "Mais de uma publicacao/artigo corresponde ao mesmo objeto auditado. Mapeamento ambiguo."
                $MsgSql = Quote-SqlString $Msg
                $DbSql = Quote-SqlString $DatabaseDestino
                $SchemaSql = Quote-SqlString $SchemaDestino
                $ObjectSql = Quote-SqlString $ObjetoDestino

                $UpdateSql = @"
UPDATE dbo.AuditoriaDml
SET
      ST_PROCESSAMENTO = 'ERRO_MAPEAMENTO'
    , DT_PROCESSAMENTO = SYSDATETIME()
    , DS_MENSAGEM = $MsgSql
WHERE
        ST_PROCESSAMENTO = 'PENDENTE_VERIFICACAO'
    AND ID <= $IdMax
    AND NM_DATABASE = $DbSql
    AND ISNULL(NM_SCHEMA, N'') = ISNULL($SchemaSql, N'')
    AND NM_OBJETO = $ObjectSql;
"@

                Invoke-SqlNonQuery -Server $Subscriber -Database $SubscriberControlDatabase -Query $UpdateSql
                Write-Output "    ERRO_MAPEAMENTO"
                continue
            }


            $Map = $UniqueMappings[0]

            $DatabaseOrigem = [string]$Map.NM_DATABASE_ORIGEM
            $Publication = [string]$Map.NM_PUBLICACAO
            $Article = [string]$Map.NM_ARTIGO


            $DbOrigemSql = Quote-SqlString $DatabaseOrigem
            $PublicationSql = Quote-SqlString $Publication
            $ArticleSql = Quote-SqlString $Article
            $SubscriberSql = Quote-SqlString $Subscriber
            $DbDestinoSql = Quote-SqlString $DatabaseDestino


            # --------------------------------------------------------
            # Nao anexa novos eventos a uma validacao que ja esta em
            # andamento. Eles permanecem PENDENTE_VERIFICACAO e serao
            # tratados no proximo ciclo apos o fluxo atual terminar.
            # --------------------------------------------------------

            $ActiveQuery = @"
SELECT TOP (1)
    ID
FROM dbo.ReplDistDiff
WHERE
        NM_DATABASE_ORIGEM = $DbOrigemSql
    AND NM_PUBLICACAO = $PublicationSql
    AND NM_ARTIGO = $ArticleSql
    AND NM_SUBSCRIBER = $SubscriberSql
    AND NM_DATABASE_DESTINO = $DbDestinoSql
    AND ST_PROCESSAMENTO IN
    (
          'PENDENTE_VALIDACAO'
        , 'PROCESSANDO_VALIDACAO'
        , 'PENDENTE_CORRECAO'
        , 'PROCESSANDO_CORRECAO'
        , 'PENDENTE_REVALIDACAO'
        , 'PROCESSANDO_REVALIDACAO'
        , 'DIVERGENTE'
    )
ORDER BY ID DESC;
"@

            $Active = Invoke-SqlDataTable `
                -Server $ControlServer `
                -Database $ControlDatabase `
                -Query $ActiveQuery

            if ($Active.Rows.Count -gt 0)
            {
                Write-Output "    Ja existe fluxo ativo. Eventos permanecem pendentes."
                continue
            }


            # --------------------------------------------------------
            # Enfileira validacao.
            # --------------------------------------------------------

            $ValidateSql = @"
EXEC dbo.SpReplValidar
      @Database = $DbOrigemSql
    , @Publication = $PublicationSql
    , @Article = $ArticleSql
    , @Subscriber = $SubscriberSql
    , @TipoValidacao = 'CONDITIONAL'
    , @ExibirDetalhes = 0;
"@

            Invoke-SqlNonQuery `
                -Server $ControlServer `
                -Database $ControlDatabase `
                -Query $ValidateSql


            # --------------------------------------------------------
            # Recupera ID criado em ReplDistDiff.
            # --------------------------------------------------------

            $QueueQuery = @"
SELECT TOP (1)
    ID
FROM dbo.ReplDistDiff
WHERE
        NM_DATABASE_ORIGEM = $DbOrigemSql
    AND NM_PUBLICACAO = $PublicationSql
    AND NM_ARTIGO = $ArticleSql
    AND NM_SUBSCRIBER = $SubscriberSql
    AND NM_DATABASE_DESTINO = $DbDestinoSql
    AND ST_PROCESSAMENTO = 'PENDENTE_VALIDACAO'
    AND TP_VALIDACAO IN ('CHECKSUM_NATIVO','CHECKSUM_CUSTOM')
ORDER BY ID DESC;
"@

            $Queue = Invoke-SqlDataTable `
                -Server $ControlServer `
                -Database $ControlDatabase `
                -Query $QueueQuery

            if ($Queue.Rows.Count -eq 0)
            {
                throw "SpReplValidar nao gerou PENDENTE_VALIDACAO para $Subscriber / $DatabaseDestino / $ObjetoDestino."
            }


            $ReplDistDiffId = [long]$Queue.Rows[0].ID
            $DbSql = Quote-SqlString $DatabaseDestino
            $SchemaSql = Quote-SqlString $SchemaDestino
            $ObjectSql = Quote-SqlString $ObjetoDestino

            $AuditUpdateSql = @"
UPDATE dbo.AuditoriaDml
SET
      ST_PROCESSAMENTO = 'ENFILEIRADO'
    , ID_REPL_DIST_DIFF = $ReplDistDiffId
    , DT_PROCESSAMENTO = SYSDATETIME()
    , DS_MENSAGEM = N'Validacao enfileirada no Publisher.'
WHERE
        ST_PROCESSAMENTO = 'PENDENTE_VERIFICACAO'
    AND ID <= $IdMax
    AND NM_DATABASE = $DbSql
    AND ISNULL(NM_SCHEMA, N'') = ISNULL($SchemaSql, N'')
    AND NM_OBJETO = $ObjectSql;
"@

            Invoke-SqlNonQuery `
                -Server $Subscriber `
                -Database $SubscriberControlDatabase `
                -Query $AuditUpdateSql

            Write-Output "    ReplDistDiff ID=$ReplDistDiffId / ENFILEIRADO"
        }
    }
    catch
    {
        Write-Output "  ERRO: $($_.Exception.Message)"
        throw
    }
}


Write-Output ""
Write-Output "Identificacao de alteracoes finalizada."
