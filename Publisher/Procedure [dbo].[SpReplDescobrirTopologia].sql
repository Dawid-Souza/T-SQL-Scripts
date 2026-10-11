USE [{{CONTROL_DATABASE}}]
GO

/****** Object:  StoredProcedure [dbo].[SpReplDescobrirTopologia]    Script Date: 29/09/2026 09:53:13 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO



CREATE OR ALTER  PROCEDURE [dbo].[SpReplDescobrirTopologia]
(
      @Database           SYSNAME = NULL
    , @Publication        SYSNAME = NULL
    , @Article            SYSNAME = NULL
    , @Subscriber         SYSNAME = NULL
    , @RetornarResultado  BIT = 1
)
AS
BEGIN

    SET NOCOUNT ON;


    DECLARE
          @DB              SYSNAME
        , @Pub             SYSNAME
        , @SQL             NVARCHAR(MAX)
        , @CriouTopologia  BIT = 0;


    ------------------------------------------------------------
    -- Tabela temporária compartilhada
    --
    -- Se a procedure foi executada diretamente:
    --      cria #ReplTopologia.
    --
    -- Se foi chamada pela SpReplValidar:
    --      #ReplTopologia já existe e será reutilizada.
    ------------------------------------------------------------

    IF OBJECT_ID('tempdb..#ReplTopologia') IS NULL
    BEGIN

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


        SET @CriouTopologia = 1;

    END;


    ------------------------------------------------------------
    -- Evita resíduos caso a tabela tenha sido criada
    -- pela procedure chamadora.
    ------------------------------------------------------------

    DELETE
    FROM #ReplTopologia;


    ------------------------------------------------------------
    -- Bancos publicados
    ------------------------------------------------------------

    CREATE TABLE #Databases
    (
        NM_DATABASE SYSNAME NOT NULL
            PRIMARY KEY
    );


    INSERT INTO #Databases
    (
        NM_DATABASE
    )
    SELECT
        D.[name]

    FROM sys.databases AS D

    WHERE
            D.[state_desc] = 'ONLINE'
        AND D.[is_published] = 1

        AND
        (
            NOT EXISTS
            (
                SELECT 1
                FROM dbo.ReplAuditTargetDatabase AS C
                WHERE C.IC_ATIVO = 1
            )
            OR EXISTS
            (
                SELECT 1
                FROM dbo.ReplAuditTargetDatabase AS C
                WHERE
                        C.IC_ATIVO = 1
                    AND C.NM_DATABASE = D.[name]
            )
        )

        AND
        (
            @Database IS NULL
            OR D.[name] = @Database
        );


    ------------------------------------------------------------
    -- Percorre bancos publicados
    ------------------------------------------------------------

    DECLARE curDB CURSOR
        LOCAL
        FAST_FORWARD
    FOR

        SELECT
            NM_DATABASE

        FROM #Databases

        ORDER BY
            NM_DATABASE;


    OPEN curDB;


    FETCH NEXT
    FROM curDB
    INTO @DB;


    WHILE @@FETCH_STATUS = 0
    BEGIN

        --------------------------------------------------------
        -- Publicações do banco
        --------------------------------------------------------

        CREATE TABLE #Publicacoes
        (
            NM_PUBLICACAO SYSNAME NOT NULL
                PRIMARY KEY
        );


        SET @SQL = N'
            SELECT
                P.[name]

            FROM ' + QUOTENAME(@DB) + N'.dbo.syspublications AS P

            WHERE
                    P.[repl_freq] = 0

                AND
                (
                    @Publication IS NULL
                    OR P.[name] = @Publication
                );
        ';


        INSERT INTO #Publicacoes
        (
            NM_PUBLICACAO
        )
        EXEC sys.sp_executesql
              @SQL
            , N'@Publication SYSNAME'
            , @Publication = @Publication;


        --------------------------------------------------------
        -- Percorre publicações
        --------------------------------------------------------

        DECLARE curPub CURSOR
            LOCAL
            FAST_FORWARD
        FOR

            SELECT
                NM_PUBLICACAO

            FROM #Publicacoes

            ORDER BY
                NM_PUBLICACAO;


        OPEN curPub;


        FETCH NEXT
        FROM curPub
        INTO @Pub;


        WHILE @@FETCH_STATUS = 0
        BEGIN

            ----------------------------------------------------
            -- Descobre:
            --
            -- artigo
            -- tabela/schema origem
            -- subscriber
            -- database destino
            -- computed columns não determinísticas
            ----------------------------------------------------

            SET @SQL = N'

                USE ' + QUOTENAME(@DB) + N';


                ;WITH Artigos AS
                (
                    SELECT
                          A.[artid]
                        , A.[objid]
                        , A.[name] AS NM_ARTIGO

                        , OBJECT_SCHEMA_NAME(A.[objid]) AS NM_SCHEMA
                        , OBJECT_NAME(A.[objid]) AS NM_TABELA

                        , COALESCE(NULLIF(A.[dest_owner], N''''), OBJECT_SCHEMA_NAME(A.[objid])) AS NM_SCHEMA_DESTINO
                        , COALESCE(NULLIF(A.[dest_table], N''''), OBJECT_NAME(A.[objid])) AS NM_TABELA_DESTINO

                    FROM dbo.sysarticles AS A

                    INNER JOIN dbo.syspublications AS P
                        ON P.[pubid] = A.[pubid]

                    WHERE
                            P.[name] = @Publication

                        AND
                        (
                            @Article IS NULL
                            OR A.[name] = @Article
                        )
                ),


                Assinaturas AS
                (
                    SELECT DISTINCT

                          A.[artid]
                        , S.[srvname] AS NM_SUBSCRIBER
                        , S.[dest_db] AS NM_DATABASE_DESTINO

                    FROM Artigos AS A

                    INNER JOIN dbo.syssubscriptions AS S
                        ON S.[artid] = A.[artid]

                    WHERE
                            S.[status] = 2

                        ------------------------------------------------
                        -- Somente subscriptions Push / Pull
                        ------------------------------------------------
                        AND S.[subscription_type] IN (0, 1)

                        ------------------------------------------------
                        -- Ignora subscriber vazio
                        ------------------------------------------------
                        AND NULLIF
                            (
                                LTRIM(RTRIM(S.[srvname])),
                                N''''
                            ) IS NOT NULL

                        ------------------------------------------------
                        -- Ignora database destino vazia
                        ------------------------------------------------
                        AND NULLIF
                            (
                                LTRIM(RTRIM(S.[dest_db])),
                                N''''
                            ) IS NOT NULL

                        ------------------------------------------------
                        -- Ignora subscriptions internas / virtuais
                        ------------------------------------------------
                        AND S.[dest_db] <> N''virtual''

                        ------------------------------------------------
                        -- Filtro opcional
                        ------------------------------------------------
                        AND
                        (
                            @Subscriber IS NULL
                            OR S.[srvname] = @Subscriber
                        )
                ),


                Computed AS
                (
                    SELECT

                          A.[artid]

                        , STRING_AGG
                          (
                              CONVERT
                              (
                                  NVARCHAR(MAX),

                                  QUOTENAME(C.[name])
                                  + N'' = ''
                                  + CC.[definition]
                              ),

                              N''; ''
                          ) AS DS_COMPUTED_NDET

                    FROM Artigos AS A

                    INNER JOIN sys.computed_columns AS CC
                        ON CC.[object_id] = A.[objid]

                    INNER JOIN sys.columns AS C
                        ON C.[object_id] = CC.[object_id]
                       AND C.[column_id] = CC.[column_id]

                    WHERE
                        COLUMNPROPERTY
                        (
                              CC.[object_id]
                            , CC.[name]
                            , ''IsDeterministic''
                        ) = 0

                    GROUP BY
                        A.[artid]
                )


                SELECT

                      DB_NAME() AS NM_DATABASE_ORIGEM
                    , @Publication AS NM_PUBLICACAO
                    , A.[NM_ARTIGO]

                    , A.[NM_SCHEMA]
                    , A.[NM_TABELA]

                    , S.[NM_SUBSCRIBER]
                    , S.[NM_DATABASE_DESTINO]

                    , A.[NM_SCHEMA_DESTINO]
                    , A.[NM_TABELA_DESTINO]

                    , CONVERT
                      (
                          BIT,

                          CASE
                              WHEN C.[artid] IS NULL
                                  THEN 0
                              ELSE 1
                          END
                      ) AS IC_COMPUTED_NDET

                    , C.[DS_COMPUTED_NDET]

                    , CASE

                          WHEN C.[artid] IS NULL
                              THEN ''CHECKSUM_NATIVO''

                          ELSE ''CHECKSUM_CUSTOM''

                      END AS TP_VALIDACAO_SUGERIDA

                FROM Artigos AS A

                INNER JOIN Assinaturas AS S
                    ON S.[artid] = A.[artid]

                LEFT JOIN Computed AS C
                    ON C.[artid] = A.[artid]

                ORDER BY
                      A.[NM_SCHEMA]
                    , A.[NM_TABELA]
                    , S.[NM_SUBSCRIBER];

            ';


            ----------------------------------------------------
            -- A própria proc escreve diretamente na temp
            -- compartilhada.
            --
            -- Não existe INSERT EXEC da procedure chamadora.
            ----------------------------------------------------

            INSERT INTO #ReplTopologia
            (
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
            )

            EXEC sys.sp_executesql
                  @SQL

                , N'
                      @Publication SYSNAME
                    , @Article SYSNAME
                    , @Subscriber SYSNAME
                  '

                , @Publication = @Pub
                , @Article = @Article
                , @Subscriber = @Subscriber;


            FETCH NEXT
            FROM curPub
            INTO @Pub;

        END;


        CLOSE curPub;
        DEALLOCATE curPub;


        DROP TABLE #Publicacoes;


        FETCH NEXT
        FROM curDB
        INTO @DB;

    END;


    CLOSE curDB;
    DEALLOCATE curDB;


    ------------------------------------------------------------
    -- Resultado
    --
    -- Execução manual:
    --     retorna normalmente.
    --
    -- Chamada pela SpReplValidar:
    --     @RetornarResultado = 0
    --     não retorna result set.
    ------------------------------------------------------------

    IF @RetornarResultado = 1
    BEGIN

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

    END;

END;
