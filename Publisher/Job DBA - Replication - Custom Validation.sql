USE [msdb];
GO

DECLARE
      @JobId UNIQUEIDENTIFIER
    , @JobName SYSNAME = N'{{PUBLISHER_JOB_NAME_STRING}}'
    , @ScheduleName SYSNAME = N'{{PUBLISHER_JOB_NAME_STRING}} - Schedule'
    , @ScheduleId INT
    , @ActiveStartDate INT = CONVERT(INT, CONVERT(CHAR(8), GETDATE(), 112));

SELECT @JobId = job_id
FROM dbo.sysjobs
WHERE [name] = @JobName;

IF @JobId IS NULL
BEGIN
    EXEC dbo.sp_add_job
          @job_name = @JobName
        , @enabled = {{JOBS_ENABLED_BIT}}
        , @description = N'Despacha DML auditado, valida e opcionalmente corrige divergencias de replicacao.'
        , @start_step_id = 1
        , @owner_login_name = N'{{JOB_OWNER_STRING}}'
        , @job_id = @JobId OUTPUT;
END
ELSE
BEGIN
    EXEC dbo.sp_update_job
          @job_id = @JobId
        , @enabled = {{JOBS_ENABLED_BIT}}
        , @description = N'Despacha DML auditado, valida e opcionalmente corrige divergencias de replicacao.'
        , @start_step_id = 1;
END;

WHILE EXISTS (SELECT 1 FROM dbo.sysjobsteps WHERE job_id = @JobId)
BEGIN
    DECLARE @StepId INT;
    SELECT TOP (1) @StepId = step_id
    FROM dbo.sysjobsteps
    WHERE job_id = @JobId
    ORDER BY step_id DESC;

    EXEC dbo.sp_delete_jobstep @job_id = @JobId, @step_id = @StepId;
END;

EXEC dbo.sp_add_jobstep
      @job_id = @JobId
    , @step_id = 1
    , @step_name = N'Identificar alteracoes auditadas'
    , @subsystem = N'PowerShell'
    , @command = N'
$ErrorActionPreference = "Stop"
$ControlServer = "$(ESCAPE_NONE(SRVR))"
& ''{{WORKER_PATH_POWERSHELL}}\Invoke-ReplAuditDispatch.ps1'' `
    -ControlServer $ControlServer `
    -ControlDatabase ''{{CONTROL_DATABASE_STRING}}'' `
    -SubscriberControlDatabase ''{{SUBSCRIBER_CONTROL_DATABASE_STRING}}'' `
    -MaxGroups {{MAX_GROUPS}} `
    -CommandTimeout {{COMMAND_TIMEOUT_SECONDS}}
if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) { throw "Dispatcher retornou ExitCode=$LASTEXITCODE" }
'
    , @database_name = N'master'
    {{PROXY_PARAMETER}}
    , @on_success_action = 4
    , @on_success_step_id = 2
    , @on_fail_action = 2;

EXEC dbo.sp_add_jobstep
      @job_id = @JobId
    , @step_id = 2
    , @step_name = N'Processar validacoes'
    , @subsystem = N'PowerShell'
    , @command = N'
$ErrorActionPreference = "Stop"
$ControlServer = "$(ESCAPE_NONE(SRVR))"
& ''{{WORKER_PATH_POWERSHELL}}\Invoke-ReplCustomValidation.ps1'' `
    -ControlServer $ControlServer `
    -ControlDatabase ''{{CONTROL_DATABASE_STRING}}'' `
    -SubscriberControlDatabase ''{{SUBSCRIBER_CONTROL_DATABASE_STRING}}'' `
    -MaxItems {{MAX_VALIDATION_ITEMS}} `
    -MaxRetries {{MAX_RETRIES}} `
    -RetrySeconds {{RETRY_SECONDS}}
if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) { throw "Validador retornou ExitCode=$LASTEXITCODE" }
'
    , @database_name = N'master'
    {{PROXY_PARAMETER}}
    , @on_success_action = {{VALIDATION_SUCCESS_ACTION}}
    , @on_success_step_id = 3
    , @on_fail_action = 2
    , @retry_attempts = 2
    , @retry_interval = 1;

EXEC dbo.sp_add_jobstep
      @job_id = @JobId
    , @step_id = 3
    , @step_name = N'Correcao automatica'
    , @subsystem = N'PowerShell'
    , @command = N'
$ErrorActionPreference = "Stop"
$ControlServer = "$(ESCAPE_NONE(SRVR))"
& ''{{WORKER_PATH_POWERSHELL}}\Invoke-ReplCorrection.ps1'' `
    -ControlServer $ControlServer `
    -ControlDatabase ''{{CONTROL_DATABASE_STRING}}'' `
    -SubscriberControlDatabase ''{{SUBSCRIBER_CONTROL_DATABASE_STRING}}'' `
    -MaxItems {{MAX_CORRECTION_ITEMS}} `
    -CommandTimeout {{COMMAND_TIMEOUT_SECONDS}}
if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) { throw "Corretor retornou ExitCode=$LASTEXITCODE" }
'
    , @database_name = N'master'
    {{PROXY_PARAMETER}}
    , @on_success_action = 1
    , @on_fail_action = 2;

DECLARE @AttachedScheduleId INT;
DECLARE ScheduleCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT schedule_id FROM dbo.sysjobschedules WHERE job_id = @JobId;

OPEN ScheduleCursor;
FETCH NEXT FROM ScheduleCursor INTO @AttachedScheduleId;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.sp_detach_schedule @job_id = @JobId, @schedule_id = @AttachedScheduleId;
    FETCH NEXT FROM ScheduleCursor INTO @AttachedScheduleId;
END;
CLOSE ScheduleCursor;
DEALLOCATE ScheduleCursor;

SELECT @ScheduleId = schedule_id
FROM dbo.sysschedules
WHERE [name] = @ScheduleName;

IF @ScheduleId IS NULL
BEGIN
    EXEC dbo.sp_add_schedule
          @schedule_name = @ScheduleName
        , @enabled = {{JOBS_ENABLED_BIT}}
        , @freq_type = 4
        , @freq_interval = 1
        , @freq_subday_type = 4
        , @freq_subday_interval = {{PUBLISHER_INTERVAL_MINUTES}}
        , @active_start_date = @ActiveStartDate
        , @active_end_date = 99991231
        , @active_start_time = 000000
        , @active_end_time = 235959
        , @schedule_id = @ScheduleId OUTPUT;
END
ELSE
BEGIN
    EXEC dbo.sp_update_schedule
          @schedule_id = @ScheduleId
        , @enabled = {{JOBS_ENABLED_BIT}}
        , @freq_type = 4
        , @freq_interval = 1
        , @freq_subday_type = 4
        , @freq_subday_interval = {{PUBLISHER_INTERVAL_MINUTES}}
        , @active_start_date = @ActiveStartDate
        , @active_end_date = 99991231
        , @active_start_time = 000000
        , @active_end_time = 235959;
END;

EXEC dbo.sp_attach_schedule @job_id = @JobId, @schedule_id = @ScheduleId;

IF NOT EXISTS (SELECT 1 FROM dbo.sysjobservers WHERE job_id = @JobId)
    EXEC dbo.sp_add_jobserver @job_id = @JobId, @server_name = N'(LOCAL)';
GO
