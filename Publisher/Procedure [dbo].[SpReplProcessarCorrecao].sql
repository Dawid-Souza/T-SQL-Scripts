USE [{{CONTROL_DATABASE}}];
GO

SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO


CREATE OR ALTER PROCEDURE [dbo].[SpReplProcessarCorrecao]
(
      @ID              BIGINT = NULL
    , @TipoValidacao   VARCHAR(30) = NULL
)
AS
BEGIN

    SET NOCOUNT ON;
    SET XACT_ABORT ON;


    DECLARE
          @IDProcessar BIGINT
        , @StatusAtual VARCHAR(30);


    BEGIN TRY

        BEGIN TRANSACTION;


        ------------------------------------------------------------
        -- Reserva uma pendência
        ------------------------------------------------------------

        IF @ID IS NULL
        BEGIN

            SELECT TOP (1)
                  @IDProcessar = D.[ID]
                , @StatusAtual = D.[ST_PROCESSAMENTO]

            FROM dbo.ReplDistDiff AS D WITH
            (
                  UPDLOCK
                , READPAST
                , ROWLOCK
            )

            WHERE
                    D.[ST_PROCESSAMENTO] = 'PENDENTE_CORRECAO'

                AND
                (
                    @TipoValidacao IS NULL
                    OR D.[TP_VALIDACAO] = @TipoValidacao
                )

            ORDER BY
                  D.[DT_INC]
                , D.[ID];

        END
        ELSE
        BEGIN

            SELECT
                  @IDProcessar = D.[ID]
                , @StatusAtual = D.[ST_PROCESSAMENTO]

            FROM dbo.ReplDistDiff AS D WITH
            (
                  UPDLOCK
                , ROWLOCK
            )

            WHERE
                    D.[ID] = @ID

                AND
                (
                    @TipoValidacao IS NULL
                    OR D.[TP_VALIDACAO] = @TipoValidacao
                );

        END;


        ------------------------------------------------------------
        -- Nenhum item encontrado
        ------------------------------------------------------------

        IF @IDProcessar IS NULL
        BEGIN

            IF @ID IS NULL
            BEGIN

                ROLLBACK TRANSACTION;
                RETURN;

            END;


            THROW 50010,
                  'ID nao encontrado ou nao corresponde ao tipo de validacao informado.',
                  1;

        END;


        ------------------------------------------------------------
        -- Valida estado
        ------------------------------------------------------------

        IF @StatusAtual <> 'PENDENTE_CORRECAO'
        BEGIN

            THROW 50011,
                  'O registro informado nao esta em PENDENTE_CORRECAO.',
                  1;

        END;


        ------------------------------------------------------------
        -- Reserva para correção
        ------------------------------------------------------------

        UPDATE dbo.ReplDistDiff

        SET
              ST_PROCESSAMENTO = 'PROCESSANDO_CORRECAO'

            , DT_INI_PROCESSAMENTO =
                COALESCE
                (
                      DT_INI_PROCESSAMENTO
                    , SYSDATETIME()
                )

            , DT_ATU = SYSDATETIME()

            , DT_FIM_PROCESSAMENTO = NULL

            , DS_MENSAGEM =
                N'Correcao em processamento pelo worker de replicacao.'

        WHERE
                ID = @IDProcessar
            AND ST_PROCESSAMENTO = 'PENDENTE_CORRECAO';


        ------------------------------------------------------------
        -- Garante que reservou
        ------------------------------------------------------------

        IF @@ROWCOUNT = 0
        BEGIN

            THROW 50012,
                  'Nao foi possivel reservar a pendencia para correcao.',
                  1;

        END;


        COMMIT TRANSACTION;


        ------------------------------------------------------------
        -- Retorna dados para o worker
        ------------------------------------------------------------

        SELECT
              D.[ID]

            , D.[NM_PUBLISHER]

            , D.[NM_DATABASE_ORIGEM]
            , D.[NM_PUBLICACAO]
            , D.[NM_ARTIGO]

            , D.[NM_SCHEMA_ORIGEM]
            , D.[NM_TABELA_ORIGEM]

            , D.[NM_SUBSCRIBER]
            , D.[NM_DATABASE_DESTINO]

            , D.[NM_SCHEMA_DESTINO]
            , D.[NM_TABELA_DESTINO]

            , D.[TP_VALIDACAO]

            , D.[IC_COMPUTED_NDET]
            , D.[DS_COLUNAS_IGNORADAS]

            , D.[NR_ROWCOUNT_ORIGEM]
            , D.[NR_ROWCOUNT_DESTINO]

            , D.[VL_CHECKSUM_ORIGEM]
            , D.[VL_CHECKSUM_DESTINO]

            , D.[ST_PROCESSAMENTO]

            , D.[DT_INI_PROCESSAMENTO]
            , D.[DT_ATU]

            , D.[DS_ARQUIVO_CORRECAO]
            , D.[DS_COMANDO_TABLEDIFF]
            , D.[NR_RETORNO_TABLEDIFF]

            , D.[DS_MENSAGEM]

        FROM dbo.ReplDistDiff AS D

        WHERE
            D.[ID] = @IDProcessar;

    END TRY

    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;

END;
