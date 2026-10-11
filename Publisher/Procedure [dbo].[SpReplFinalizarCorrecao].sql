USE [{{CONTROL_DATABASE}}];
GO

SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO


CREATE OR ALTER PROCEDURE [dbo].[SpReplFinalizarCorrecao]
(
      @ID                BIGINT
    , @StatusRevalidacao VARCHAR(30)
    , @Mensagem          NVARCHAR(MAX) = NULL
)
AS
BEGIN

    SET NOCOUNT ON;
    SET XACT_ABORT ON;


    DECLARE
          @StatusAtual VARCHAR(30)
        , @Existe      BIT = 0;


    ------------------------------------------------------------
    -- Normaliza parâmetro
    ------------------------------------------------------------

    SET @StatusRevalidacao =
        UPPER
        (
            LTRIM
            (
                RTRIM(@StatusRevalidacao)
            )
        );


    ------------------------------------------------------------
    -- Valida status informado
    ------------------------------------------------------------

    IF @StatusRevalidacao NOT IN
    (
          'OK'
        , 'DIVERGENTE'
        , 'ERRO'
    )
    BEGIN

        THROW 50000,
              'Status de revalidacao invalido. Use OK, DIVERGENTE ou ERRO.',
              1;

    END;


    ------------------------------------------------------------
    -- Verifica se o ID existe
    ------------------------------------------------------------

    SELECT
          @Existe = 1
        , @StatusAtual = D.[ST_PROCESSAMENTO]

    FROM dbo.ReplDistDiff AS D

    WHERE
        D.[ID] = @ID;


    IF @Existe = 0
    BEGIN

        THROW 50001,
              'ID nao encontrado em dbo.ReplDistDiff.',
              1;

    END;


    ------------------------------------------------------------
    -- A finalização só pode acontecer após a correção ter sido
    -- aplicada e o registro estar em fase de revalidação.
    ------------------------------------------------------------

    IF @StatusAtual NOT IN
    (
          'PENDENTE_REVALIDACAO'
        , 'PROCESSANDO_REVALIDACAO'
    )
    BEGIN

        THROW 50002,
              'A divergencia nao esta em fase de revalidacao e nao pode ser finalizada.',
              1;

    END;


    ------------------------------------------------------------
    -- DIVERGENTE
    --
    -- A correção foi aplicada/revalidada, porém a divergência
    -- ainda permanece.
    --
    -- Mantém em ReplDistDiff para análise ou nova tentativa.
    ------------------------------------------------------------

    IF @StatusRevalidacao = 'DIVERGENTE'
    BEGIN

        UPDATE dbo.ReplDistDiff

        SET
              ST_PROCESSAMENTO = 'DIVERGENTE'

            , DT_ATU = SYSDATETIME()

            , DT_FIM_PROCESSAMENTO = SYSDATETIME()

            , DT_REVALIDACAO = SYSDATETIME()

            , ST_REVALIDACAO = 'DIVERGENTE'

            , DS_MENSAGEM =
                COALESCE
                (
                      @Mensagem
                    , N'Revalidacao executada, mas a divergencia permanece.'
                )

        WHERE
            ID = @ID;


        RETURN;

    END;


    ------------------------------------------------------------
    -- ERRO
    --
    -- Houve erro durante a revalidação.
    --
    -- Mantém na fila para análise.
    ------------------------------------------------------------

    IF @StatusRevalidacao = 'ERRO'
    BEGIN

        UPDATE dbo.ReplDistDiff

        SET
              ST_PROCESSAMENTO = 'ERRO_REVALIDACAO'

            , DT_ATU = SYSDATETIME()

            , DT_FIM_PROCESSAMENTO = SYSDATETIME()

            , DT_REVALIDACAO = SYSDATETIME()

            , ST_REVALIDACAO = 'ERRO'

            , DS_MENSAGEM =
                COALESCE
                (
                      @Mensagem
                    , N'Erro durante a revalidacao.'
                )

        WHERE
            ID = @ID;


        RETURN;

    END;


    ------------------------------------------------------------
    -- OK
    --
    -- A divergência foi corrigida e a revalidação confirmou
    -- convergência.
    --
    -- Move para histórico e remove da fila.
    ------------------------------------------------------------

    BEGIN TRY

        BEGIN TRANSACTION;


        --------------------------------------------------------
        -- Marca como corrigido
        --------------------------------------------------------

        UPDATE dbo.ReplDistDiff

        SET
              ST_PROCESSAMENTO = 'CORRIGIDO'

            , DT_ATU = SYSDATETIME()

            , DT_FIM_PROCESSAMENTO = SYSDATETIME()

            , DT_REVALIDACAO = SYSDATETIME()

            , ST_REVALIDACAO = 'OK'

            , DS_MENSAGEM =
                COALESCE
                (
                      @Mensagem
                    , N'Divergencia corrigida e revalidada com sucesso.'
                )

        WHERE
            ID = @ID;


        --------------------------------------------------------
        -- Confirma que ainda existe antes de mover
        --------------------------------------------------------

        IF @@ROWCOUNT = 0
        BEGIN

            THROW 50003,
                  'O registro nao foi encontrado para atualizacao antes da finalizacao.',
                  1;

        END;


        --------------------------------------------------------
        -- Move para histórico
        --------------------------------------------------------

        INSERT INTO dbo.ReplHisDistDiff
        (
              ID_DIST_DIFF

            , DT_INC
            , DT_ATU

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

            , NR_ROWCOUNT_ORIGEM
            , NR_ROWCOUNT_DESTINO

            , VL_CHECKSUM_ORIGEM
            , VL_CHECKSUM_DESTINO

            , NR_ERRO_REPL
            , DS_ERRO_REPL

            , ST_FINAL

            , DT_INI_PROCESSAMENTO
            , DT_FIM_PROCESSAMENTO

            , DS_ARQUIVO_CORRECAO
            , DS_COMANDO_TABLEDIFF
            , NR_RETORNO_TABLEDIFF

            , DS_MENSAGEM

            , DT_REVALIDACAO
            , ST_REVALIDACAO
        )

        SELECT
              D.[ID]

            , D.[DT_INC]
            , D.[DT_ATU]

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

            , D.[NR_ERRO_REPL]
            , D.[DS_ERRO_REPL]

            , D.[ST_PROCESSAMENTO]

            , D.[DT_INI_PROCESSAMENTO]
            , D.[DT_FIM_PROCESSAMENTO]

            , D.[DS_ARQUIVO_CORRECAO]
            , D.[DS_COMANDO_TABLEDIFF]
            , D.[NR_RETORNO_TABLEDIFF]

            , D.[DS_MENSAGEM]

            , D.[DT_REVALIDACAO]
            , D.[ST_REVALIDACAO]

        FROM dbo.ReplDistDiff AS D

        WHERE
            D.[ID] = @ID;


        --------------------------------------------------------
        -- Confirma que foi enviado para histórico
        --------------------------------------------------------

        IF @@ROWCOUNT = 0
        BEGIN

            THROW 50004,
                  'Falha ao inserir o registro em dbo.ReplHisDistDiff.',
                  1;

        END;


        --------------------------------------------------------
        -- Remove da fila de pendências
        --------------------------------------------------------

        DELETE
        FROM dbo.ReplDistDiff

        WHERE
            ID = @ID;


        --------------------------------------------------------
        -- Confirma remoção
        --------------------------------------------------------

        IF @@ROWCOUNT = 0
        BEGIN

            THROW 50005,
                  'Falha ao remover o registro de dbo.ReplDistDiff.',
                  1;

        END;


        COMMIT TRANSACTION;

    END TRY

    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;


        THROW;

    END CATCH;

END;
