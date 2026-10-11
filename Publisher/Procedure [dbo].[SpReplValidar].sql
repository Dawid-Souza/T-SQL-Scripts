USE [{{CONTROL_DATABASE}}]
GO

/****** Object:  StoredProcedure [dbo].[SpReplValidar]    Script Date: 29/09/2026 09:53:49 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO



CREATE OR ALTER PROCEDURE [dbo].[SpReplValidar]
(
      @Database       SYSNAME     = NULL
    , @Publication    SYSNAME     = NULL
    , @Article        SYSNAME     = NULL
    , @Subscriber     SYSNAME     = NULL
    , @TipoValidacao  VARCHAR(20) = 'CONDITIONAL'
    , @ExibirDetalhes BIT         = 1
)
AS
BEGIN

    SET NOCOUNT ON;
    SET XACT_ABORT ON;


    DECLARE
          @DB                    SYSNAME
        , @Pub                   SYSNAME
        , @Art                   SYSNAME

        , @SchemaOrigem          SYSNAME
        , @TabelaOrigem          SYSNAME

        , @Sub                   SYSNAME
        , @DBDestino             SYSNAME

        , @SchemaDestino         SYSNAME
        , @TabelaDestino         SYSNAME

        , @ComputedNDet          BIT
        , @ComputedList          NVARCHAR(MAX)

        , @TipoSugerido          VARCHAR(30)

        , @SQL                   NVARCHAR(MAX)

        , @QtdRowCount           INT = 0
        , @QtdNativo             INT = 0
        , @QtdCustom             INT = 0

        , @Mensagem              NVARCHAR(4000);


    ------------------------------------------------------------
    -- Normalização
    ------------------------------------------------------------

    SET @TipoValidacao =
        UPPER
        (
            LTRIM
            (
                RTRIM(@TipoValidacao)
            )
        );


    ------------------------------------------------------------
    -- Tipos aceitos
    ------------------------------------------------------------

    IF @TipoValidacao NOT IN
    (
          'ROWCOUNT'
        , 'CHECKSUM'
        , 'CONDITIONAL'
        , 'FULL'
    )
    BEGIN

        THROW 50000,
              'Tipo de validacao invalido. Utilize ROWCOUNT, CHECKSUM, CONDITIONAL ou FULL.',
              1;

    END;


    ------------------------------------------------------------
    -- Topologia compartilhada com
    -- dbo.SpReplDescobrirTopologia
    ------------------------------------------------------------

    CREATE TABLE #ReplTopologia
    (
          NM_DATABASE_ORIGEM      SYSNAME
        , NM_PUBLICACAO           SYSNAME
        , NM_ARTIGO               SYSNAME

        , NM_SCHEMA_ORIGEM        SYSNAME
        , NM_TABELA_ORIGEM        SYSNAME

        , NM_SUBSCRIBER           SYSNAME
        , NM_DATABASE_DESTINO     SYSNAME

        , NM_SCHEMA_DESTINO       SYSNAME
        , NM_TABELA_DESTINO       SYSNAME

        , IC_COMPUTED_NDET        BIT
        , DS_COMPUTED_NDET        NVARCHAR(MAX)

        , TP_VALIDACAO_SUGERIDA   VARCHAR(30)
    );


    ------------------------------------------------------------
    -- Resultado da execução
    ------------------------------------------------------------

    CREATE TABLE #Resultado
    (
          NM_DATABASE_ORIGEM   SYSNAME
        , NM_PUBLICACAO        SYSNAME
        , NM_ARTIGO            SYSNAME
        , NM_SUBSCRIBER        SYSNAME

        , TP_VALIDACAO         VARCHAR(30)

        , DS_ACAO              VARCHAR(50)
        , DS_MENSAGEM          NVARCHAR(4000)
    );


    ------------------------------------------------------------
    -- Descobre topologia
    ------------------------------------------------------------

    EXEC dbo.SpReplDescobrirTopologia
          @Database          = @Database
        , @Publication       = @Publication
        , @Article           = @Article
        , @Subscriber        = @Subscriber
        , @RetornarResultado = 0;


    ------------------------------------------------------------
    -- Nenhum artigo encontrado
    ------------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1
        FROM #ReplTopologia
    )
    BEGIN

        RAISERROR
        (
            'Nenhuma topologia encontrada para os filtros informados.',
            10,
            1
        );

        RETURN;

    END;


    ------------------------------------------------------------
    -- Processamento
    ------------------------------------------------------------

    DECLARE curValidacao CURSOR
        LOCAL
        FAST_FORWARD
    FOR

        SELECT
              NM_DATABASE_ORIGEM
            , NM_PUBLICACAO
            , NM_ARTIGO

            , NM_SCHEMA_ORIGEM
            , NM_TABELA_ORIGEM

            , NM_SUBSCRIBER
            , NM_DATABASE_DESTINO

            , NM_SCHEMA_DESTINO
            , NM_TABELA_DESTINO

            , IC_COMPUTED_NDET
            , DS_COMPUTED_NDET

            , TP_VALIDACAO_SUGERIDA

        FROM #ReplTopologia

        ORDER BY
              NM_DATABASE_ORIGEM
            , NM_PUBLICACAO
            , NM_ARTIGO
            , NM_SUBSCRIBER;


    OPEN curValidacao;


    FETCH NEXT
    FROM curValidacao
    INTO
          @DB
        , @Pub
        , @Art

        , @SchemaOrigem
        , @TabelaOrigem

        , @Sub
        , @DBDestino

        , @SchemaDestino
        , @TabelaDestino

        , @ComputedNDet
        , @ComputedList

        , @TipoSugerido;


    WHILE @@FETCH_STATUS = 0
    BEGIN

        BEGIN TRY


            ----------------------------------------------------
            -- ROWCOUNT
            --
            -- Mantém validação nativa de RowCount.
            --
            -- Como não existe comparação de conteúdo das
            -- colunas, computed não determinística não interfere.
            ----------------------------------------------------

            IF @TipoValidacao = 'ROWCOUNT'
            BEGIN

                SET @SQL = N'

                    USE ' + QUOTENAME(@DB) + N';

                    SET XACT_ABORT ON;

                    BEGIN TRY

                        BEGIN TRANSACTION;


                        EXEC dbo.sp_marksubscriptionvalidation
                              @publication    = @Publication
                            , @subscriber     = @Subscriber
                            , @destination_db = @DestinationDB;


                        EXEC dbo.sp_article_validation
                              @publication    = @Publication
                            , @article        = @Article
                            , @rowcount_only = 1
                            , @full_or_fast  = 2;


                        COMMIT TRANSACTION;

                    END TRY

                    BEGIN CATCH

                        IF @@TRANCOUNT > 0
                            ROLLBACK TRANSACTION;

                        THROW;

                    END CATCH;

                ';


                EXEC sys.sp_executesql
                      @SQL
                    , N'
                           @Publication SYSNAME
                         , @Article SYSNAME
                         , @Subscriber SYSNAME
                         , @DestinationDB SYSNAME
                      '
                    , @Publication   = @Pub
                    , @Article       = @Art
                    , @Subscriber    = @Sub
                    , @DestinationDB = @DBDestino;


                SET @QtdRowCount += 1;


                INSERT INTO #Resultado
                (
                      NM_DATABASE_ORIGEM
                    , NM_PUBLICACAO
                    , NM_ARTIGO
                    , NM_SUBSCRIBER
                    , TP_VALIDACAO
                    , DS_ACAO
                    , DS_MENSAGEM
                )
                VALUES
                (
                      @DB
                    , @Pub
                    , @Art
                    , @Sub
                    , 'ROWCOUNT'
                    , 'VALIDACAO_NATIVA'
                    , N'Validação nativa de RowCount enviada ao Distribution Agent.'
                );

            END


            ----------------------------------------------------
            -- CHECKSUM / CONDITIONAL / FULL
            --
            -- Todos utilizam o mesmo worker.
            --
            -- CHECKSUM_NATIVO
            --      Não possui computed não determinística.
            --      Worker utiliza todas as colunas publicadas.
            --
            -- CHECKSUM_CUSTOM
            --      Possui computed não determinística.
            --      Worker ignora somente essas colunas.
            ----------------------------------------------------

            ELSE
            BEGIN

                ------------------------------------------------
                -- Garante classificação coerente
                ------------------------------------------------

                SET @TipoSugerido =
                    CASE
                        WHEN ISNULL(@ComputedNDet, 0) = 1
                            THEN 'CHECKSUM_CUSTOM'

                        ELSE 'CHECKSUM_NATIVO'
                    END;


                ------------------------------------------------
                -- Evita duplicar processamento ativo
                ------------------------------------------------

                IF NOT EXISTS
                (
                    SELECT 1

                    FROM dbo.ReplDistDiff AS D
                         WITH (READUNCOMMITTED)

                    WHERE
                            D.[NM_DATABASE_ORIGEM] = @DB
                        AND D.[NM_PUBLICACAO] = @Pub
                        AND D.[NM_ARTIGO] = @Art
                        AND D.[NM_SUBSCRIBER] = @Sub
                        AND D.[NM_DATABASE_DESTINO] = @DBDestino

                        AND D.[TP_VALIDACAO] = @TipoSugerido

                        AND D.[ST_PROCESSAMENTO] IN
                        (
                              'PENDENTE_VALIDACAO'
                            , 'PROCESSANDO_VALIDACAO'

                            , 'PENDENTE_CORRECAO'
                            , 'PROCESSANDO_CORRECAO'

                            , 'PENDENTE_REVALIDACAO'
                            , 'PROCESSANDO_REVALIDACAO'

                            , 'DIVERGENTE'
                        )
                )
                BEGIN


                    ------------------------------------------------
                    -- Insere na fila
                    ------------------------------------------------

                    INSERT INTO dbo.ReplDistDiff
                    (
                          DT_INC

                        , NM_PUBLISHER

                        , NM_DATABASE_ORIGEM
                        , NM_PUBLICACAO
                        , NM_ARTIGO

                        , NM_SCHEMA_ORIGEM
                        , NM_TABELA_ORIGEM

                        , NM_SUBSCRIBER
                        , NM_DATABASE_DESTINO

                        , NM_SCHEMA_DESTINO
                        , NM_TABELA_DESTINO

                        , TP_VALIDACAO

                        , IC_COMPUTED_NDET
                        , DS_COLUNAS_IGNORADAS

                        , ST_PROCESSAMENTO

                        , DS_MENSAGEM
                    )
                    VALUES
                    (
                          SYSDATETIME()

                        , CONVERT
                          (
                              SYSNAME,
                              SERVERPROPERTY('ServerName')
                          )

                        , @DB
                        , @Pub
                        , @Art

                        , @SchemaOrigem
                        , @TabelaOrigem

                        , @Sub
                        , @DBDestino


                        , COALESCE(@SchemaDestino, @SchemaOrigem)
                        , COALESCE(@TabelaDestino, @TabelaOrigem)


                        ------------------------------------------------
                        -- Apenas classificação do método
                        ------------------------------------------------

                        , @TipoSugerido


                        ------------------------------------------------
                        -- Computed não determinística
                        ------------------------------------------------

                        , ISNULL(@ComputedNDet, 0)

                        , CASE
                              WHEN ISNULL(@ComputedNDet, 0) = 1
                                  THEN @ComputedList

                              ELSE NULL
                          END


                        ------------------------------------------------
                        -- Estado inicial
                        ------------------------------------------------

                        , 'PENDENTE_VALIDACAO'


                        ------------------------------------------------
                        -- Mensagem
                        ------------------------------------------------

                        , CASE
                              WHEN @TipoSugerido = 'CHECKSUM_CUSTOM'
                                  THEN N'Aguardando validação CHECKSUM_CUSTOM. Colunas computed não determinísticas serão ignoradas.'

                              ELSE N'Aguardando validação CHECKSUM_NATIVO. Todas as colunas publicadas serão utilizadas.'
                          END
                    );


                    ------------------------------------------------
                    -- Contadores
                    ------------------------------------------------

                    IF @TipoSugerido = 'CHECKSUM_CUSTOM'
                    BEGIN

                        SET @QtdCustom += 1;

                    END
                    ELSE
                    BEGIN

                        SET @QtdNativo += 1;

                    END;


                    ------------------------------------------------
                    -- Resultado
                    ------------------------------------------------

                    INSERT INTO #Resultado
                    (
                          NM_DATABASE_ORIGEM
                        , NM_PUBLICACAO
                        , NM_ARTIGO
                        , NM_SUBSCRIBER

                        , TP_VALIDACAO

                        , DS_ACAO
                        , DS_MENSAGEM
                    )
                    VALUES
                    (
                          @DB
                        , @Pub
                        , @Art
                        , @Sub

                        , @TipoSugerido

                        , 'ENFILEIRADO'

                        , CASE
                              WHEN @TipoSugerido = 'CHECKSUM_CUSTOM'
                                  THEN N'Validação CHECKSUM_CUSTOM adicionada à fila.'

                              ELSE N'Validação CHECKSUM_NATIVO adicionada à fila.'
                          END
                    );

                END

                ELSE
                BEGIN


                    ------------------------------------------------
                    -- Já existe processamento ativo
                    ------------------------------------------------

                    INSERT INTO #Resultado
                    (
                          NM_DATABASE_ORIGEM
                        , NM_PUBLICACAO
                        , NM_ARTIGO
                        , NM_SUBSCRIBER

                        , TP_VALIDACAO

                        , DS_ACAO
                        , DS_MENSAGEM
                    )
                    VALUES
                    (
                          @DB
                        , @Pub
                        , @Art
                        , @Sub

                        , @TipoSugerido

                        , 'JA_PENDENTE'

                        , N'Já existe processamento pendente para este artigo/subscriber.'
                    );

                END;

            END;


        END TRY

        BEGIN CATCH

            SET @Mensagem =
                  N'Erro '
                + CONVERT(NVARCHAR(20), ERROR_NUMBER())
                + N': '
                + ERROR_MESSAGE();


            INSERT INTO #Resultado
            (
                  NM_DATABASE_ORIGEM
                , NM_PUBLICACAO
                , NM_ARTIGO
                , NM_SUBSCRIBER

                , TP_VALIDACAO

                , DS_ACAO
                , DS_MENSAGEM
            )
            VALUES
            (
                  @DB
                , @Pub
                , @Art
                , @Sub

                , ISNULL(@TipoSugerido, 'ERRO')

                , 'ERRO'
                , @Mensagem
            );


            IF @ExibirDetalhes = 1
            BEGIN

                RAISERROR
                (
                    '%s',
                    10,
                    1,
                    @Mensagem
                ) WITH NOWAIT;

            END;

        END CATCH;


        FETCH NEXT
        FROM curValidacao
        INTO
              @DB
            , @Pub
            , @Art

            , @SchemaOrigem
            , @TabelaOrigem

            , @Sub
            , @DBDestino

            , @SchemaDestino
            , @TabelaDestino

            , @ComputedNDet
            , @ComputedList

            , @TipoSugerido;

    END;


    CLOSE curValidacao;
    DEALLOCATE curValidacao;


    ------------------------------------------------------------
    -- Resultado
    ------------------------------------------------------------

    IF @ExibirDetalhes = 1
    BEGIN

        SELECT
              NM_DATABASE_ORIGEM
            , NM_PUBLICACAO
            , NM_ARTIGO
            , NM_SUBSCRIBER

            , TP_VALIDACAO

            , DS_ACAO
            , DS_MENSAGEM

        FROM #Resultado

        ORDER BY
              NM_DATABASE_ORIGEM
            , NM_PUBLICACAO
            , NM_ARTIGO
            , NM_SUBSCRIBER;


        SELECT
              @QtdRowCount AS [ValidacoesRowCountNativas]
            , @QtdNativo   AS [ChecksumNativoEnfileirado]
            , @QtdCustom   AS [ChecksumCustomEnfileirado];

    END;

END;
GO
