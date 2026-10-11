USE [msdb];
GO

DECLARE @JobName SYSNAME = N'{{SUBSCRIBER_JOB_NAME_STRING}}';

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE [name] = @JobName)
BEGIN
    EXEC dbo.sp_delete_job
          @job_name = @JobName
        , @delete_unused_schedule = 1;
END;
GO

DECLARE
      @ReturnCode INT = 0
    , @JobId UNIQUEIDENTIFIER
    , @ActiveStartDate INT = CONVERT(INT, CONVERT(CHAR(8), GETDATE(), 112));

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.syscategories
    WHERE [name] = N'REPL-Checkup'
      AND category_class = 1
)
BEGIN
    EXEC @ReturnCode = dbo.sp_add_category
          @class = N'JOB'
        , @type = N'LOCAL'
        , @name = N'REPL-Checkup';

    IF @ReturnCode <> 0
        THROW 50000, 'Falha ao criar categoria do SQL Agent.', 1;
END;

EXEC @ReturnCode = dbo.sp_add_job
      @job_name = N'{{SUBSCRIBER_JOB_NAME_STRING}}'
    , @enabled = {{JOBS_ENABLED_BIT}}
    , @notify_level_eventlog = 2
    , @description = N'Coleta SQL Server Audit DML no banco de controle configurado.'
    , @category_name = N'REPL-Checkup'
    , @owner_login_name = N'{{JOB_OWNER_STRING}}'
    , @job_id = @JobId OUTPUT;

IF @ReturnCode <> 0
    THROW 50001, 'Falha ao criar job de coleta DML.', 1;

EXEC @ReturnCode = dbo.sp_add_jobstep
      @job_id = @JobId
    , @step_name = N'Capturar DML'
    , @step_id = 1
    , @subsystem = N'TSQL'
    , @database_name = N'{{SUBSCRIBER_CONTROL_DATABASE_STRING}}'
    , @command = N'EXEC dbo.SpAuditoriaDmlCapturar;'
    , @on_success_action = 1
    , @on_fail_action = 2;

IF @ReturnCode <> 0
    THROW 50002, 'Falha ao criar step do job de coleta DML.', 1;

EXEC dbo.sp_add_jobschedule
      @job_id = @JobId
    , @name = N'{{SUBSCRIBER_JOB_NAME_STRING}} - Schedule'
    , @enabled = {{JOBS_ENABLED_BIT}}
    , @freq_type = 4
    , @freq_interval = 1
    , @freq_subday_type = 4
    , @freq_subday_interval = {{COLLECTOR_INTERVAL_MINUTES}}
    , @active_start_date = @ActiveStartDate
    , @active_end_date = 99991231
    , @active_start_time = 000000
    , @active_end_time = 235959;

EXEC dbo.sp_add_jobserver
      @job_id = @JobId
    , @server_name = N'(LOCAL)';
GO
