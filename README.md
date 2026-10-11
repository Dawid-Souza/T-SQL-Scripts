# Auditoria, validação e correção de replicação transacional

Este repositório instala e opera um fluxo para **verificar** e, quando habilitado, **corrigir** divergências de uma replicação transacional do SQL Server.

O gatilho é um DML (`INSERT`, `UPDATE` ou `DELETE`) capturado no Subscriber. O objeto auditado é cruzado com a topologia publicada. O artigo correspondente é comparado entre a origem e o destino. Se os conjuntos baterem, o evento encerra. Se divergirem, o item fica na fila para análise ou para correção automática, que alinha o Subscriber à chave primária do Publisher e revalida o resultado.

Servidor, banco, login, caminho, job, e-mail e limites ficam somente em `configuracao.json`. Publicações, artigos e nomes de destino (`dest_owner` / `dest_table`) são descobertos na metadata da replicação.

O desenho do fluxo está em [Fluxo de Auditoria DML e Correção.png](Fluxo%20de%20Auditoria%20DML%20e%20Corre%C3%A7%C3%A3o.png) e em [Modelo Conceitual.txt](Modelo%20Conceitual.txt).

```text
configuracao.json
        |
        v
Start-Replicacao.ps1
        |
        +-------------------------+
        |                         |
        v                         v
Publisher / controle        Subscriber
        |                         |
        |                         +--> Server Audit
        |                         +--> Audit Specification por banco
        |                         +--> SpAuditoriaDmlCapturar
        |                         +--> AuditoriaDml
        |                                      |
        +<--------------------------- Invoke-ReplAuditDispatch
        |
        v
SpReplValidar / ReplDistDiff
        |
        +--> checksum igual: encerra o evento
        |
        +--> divergente
                  |
                  +--> AutomaticCorrectionEnabled = false: fica em PENDENTE_CORRECAO
                  |
                  +--> AutomaticCorrectionEnabled = true
                              |
                              v
                     correção por chave primária
                              |
                              v
                     revalidação / ReplHisDistDiff
```

Os arquivos `.sql` e os workers em `Publisher/` e `Subscriber/` são modelos. `Start-Replicacao.ps1` substitui os tokens `{{...}}` e os aplica. Eles não devem ser executados direto no SSMS.

## Scripts

### Entrada

| Arquivo | Função |
| --- | --- |
| `Start-Replicacao.ps1` | Lê a configuração, cria os bancos de controle, aplica os scripts, copia os workers e cria os jobs do SQL Agent. Pode ser executado de novo. Preserva `AuditoriaDml`, `ReplDistDiff` e `ReplHisDistDiff`. |
| `configuracao.json` | Único arquivo que o operador edita no uso normal: Publisher, bancos de origem, Subscribers, conta do worker e contas ignoradas na coleta. |
| `configuracao.completa.exemplo.json` | Referência dos demais campos: TLS, Audit, e-mail, proxy, nomes de job, intervalos e limites de processamento. |
| `Modelo Conceitual.txt` | Esquema textual do fluxo. |
| `Fluxo de Auditoria DML e Correção.png` | Diagrama do mesmo fluxo. |

### Publisher — controle, fila e correção

O job do Publisher (`DBA - Replication - Custom Validation`, nome configurável) roda três passos PowerShell: despachar auditoria, validar e, se a correção automática estiver ligada, corrigir.

| Arquivo | Função |
| --- | --- |
| `00_Publisher_Configuracao.sql` | Cria `ReplAuditTargetDatabase`, a lista de bancos de origem acompanhados. |
| `Tabela [dbo].[ReplDistDiff].sql` | Fila de cada artigo/destino em validação ou correção: rowcount, checksum, status e mensagem. |
| `Tabela [dbo].[ReplHisDistDiff].sql` | Histórico dos itens cuja revalidação confirmou a correção. |
| `Procedure [dbo].[SpReplDescobrirTopologia].sql` | Lê publicações, artigos, subscribers, banco/schema/tabela de destino e colunas computadas não determinísticas. |
| `Procedure [dbo].[SpReplValidar].sql` | Enfileira a verificação do artigo. `ROWCOUNT` usa `sp_article_validation`. `CHECKSUM`, `CONDITIONAL` e `FULL` entram na fila como `CHECKSUM_NATIVO` ou `CHECKSUM_CUSTOM`. |
| `Procedure [dbo].[SpReplProcessarCorrecao].sql` | Reserva um item `PENDENTE_CORRECAO` para o worker, com bloqueio de fila. |
| `Procedure [dbo].[SpReplFinalizarCorrecao].sql` | Depois da revalidação: `OK` move o item para `ReplHisDistDiff`; divergência ou erro permanece na fila. |
| `Invoke-ReplAuditDispatch.ps1` | Lê grupos pendentes em `AuditoriaDml`, resolve o artigo na topologia e chama `SpReplValidar`. Objeto fora da publicação vira `NAO_PUBLICADO`. Mapeamento ambíguo vira `ERRO_MAPEAMENTO`. |
| `Invoke-ReplCustomValidation.ps1` | Compara rowcount e `CHECKSUM_AGG(BINARY_CHECKSUM(...))` das colunas publicadas. Checksum igual remove o item da fila. Divergência confirmada após as retentativas vai para `PENDENTE_CORRECAO`. `CHECKSUM_CUSTOM` ignora colunas computadas não determinísticas. |
| `Invoke-ReplCorrection.ps1` | Lê origem e destino pela chave primária publicada e aplica no Subscriber o `INSERT`, `UPDATE` ou `DELETE` necessário. Em seguida revalida e chama `SpReplFinalizarCorrecao`. Exige chave primária. |
| `Job DBA - Replication - Custom Validation.sql` | Cria o job orquestrador no SQL Agent do Publisher. |
| `06_Publisher_Permissoes.sql` | Concede ao `WorkerLogin` leitura da configuração, manutenção da fila/histórico e execução das procedures. |
| `Credencial da replicação.sql` | Associa o proxy do SQL Agent ao subsystem PowerShell quando `SqlAgent.ProxyName` está preenchido. |

### Subscriber — captura do DML

| Arquivo | Função |
| --- | --- |
| `01_Assinante_Auditoria_DML_DINAMICO.sql` | Cria um Server Audit na instância e uma Database Audit Specification por banco, para `INSERT`, `UPDATE` e `DELETE`. |
| `02_Assinante_AuditoriaDml_FULLSCAN_SEQUENCE_GROUP.sql` | Cria `AuditoriaDml`, o controle de leitura dos arquivos de audit, as contas excluídas, as configurações e `SpAuditoriaDmlCapturar`. Uma nova instalação preserva os eventos já coletados. |
| `03_Assinante_Job_Coleta_AuditoriaDml.sql` | Job do SQL Agent que executa `SpAuditoriaDmlCapturar` no intervalo configurado. |
| `04_Assinante_Trigger_Envio_email_Informando_Divergencia.sql` | Trigger opcional que avisa por Database Mail quando entra um evento de um principal que não está na lista de exclusão. |
| `06_Assinante_Permissoes_AuditoriaDml.sql` | Concede ao `WorkerLogin` `SELECT` e `UPDATE` em `AuditoriaDml`. |

## Status

`AuditoriaDml` no Subscriber:

| Status | Significado |
| --- | --- |
| `PENDENTE_VERIFICACAO` | Evento coletado, ainda sem artigo associado. |
| `ENFILEIRADO` | Artigo localizado e validação criada em `ReplDistDiff`. |
| `NAO_PUBLICADO` | Objeto auditado não pertence à topologia. |
| `ERRO_MAPEAMENTO` | O mesmo objeto corresponde a mais de uma publicação/artigo. |
| `OK` | Validação ou revalidação sem divergência. |
| `DIVERGENTE` | Origem e destino diferem; aguarda correção ou nova análise. |
| `ERRO_VALIDACAO` | Falha ao comparar os conjuntos. |

`ReplDistDiff` no Publisher percorre `PENDENTE_VALIDACAO`, `PROCESSANDO_VALIDACAO`, `PENDENTE_CORRECAO`, `PROCESSANDO_CORRECAO`, `PENDENTE_REVALIDACAO` e `PROCESSANDO_REVALIDACAO`. Conclusão com sucesso sai da fila e entra em `ReplHisDistDiff`. `DIVERGENTE` e `ERRO_VALIDACAO` permanecem para análise.

## Uso

1. Edite `configuracao.json`.
2. Informe o Publisher em `ControlServer`, os bancos de origem em `PublisherDatabases` e um ou mais itens em `Subscribers`.
3. Informe em `WorkerLogin` a conta Windows dos steps PowerShell: a conta do SQL Agent quando `ProxyName` estiver vazio, ou a identidade da Credential quando houver proxy.
4. Abra o PowerShell com uma conta `sysadmin` nas instâncias envolvidas.
5. Execute a partir desta pasta:

```powershell
.\Start-Replicacao.ps1
```

Para ver o plano sem alterar o SQL Server nem copiar os workers:

```powershell
.\Start-Replicacao.ps1 -WhatIf
```

Para usar outro arquivo:

```powershell
.\Start-Replicacao.ps1 -ConfigPath .\configuracao.producao.json
```

Os demais valores têm default. Caminho, TLS, Audit, e-mail, proxy, jobs e limites estão em `configuracao.completa.exemplo.json`.

Depois da instalação, confira o histórico dos dois jobs e execute `dbo.SpReplDescobrirTopologia` no banco de controle para revisar artigos e destinos descobertos.

## Configuração

- `Subscribers[].AuditPath` vazio usa `<SQLPath>\Audit\` da própria instância.
- `ExcludedPrincipals` lista contas ignoradas na coleta. Em geral é a conta do Distribution Agent. `WorkerLogin` também é excluído, para uma correção não abrir outro ciclo de auditoria.
- `Email.Enabled` só deve ser `true` se o Database Mail e o profile já existirem em cada Subscriber.
- `SqlAgent.ProxyName` vazio executa os workers como a conta do serviço SQL Agent. Se o nome for informado e o proxy ainda não existir, `CredentialName` precisa apontar para uma Credential já criada.
- `InstallPath` precisa ser visível no host onde o SQL Agent do Publisher executa. Para Publisher remoto, use um caminho UNC acessível pela conta do Agent ou do proxy, ou execute o Start no próprio host.
- `Connection.Encrypt` segue a política TLS do ambiente.

## Correção automática

`Processing.AutomaticCorrectionEnabled` vem como `false`. Nesse modo o job identifica e valida divergências e encerra antes do passo que executa `INSERT`, `UPDATE` e `DELETE` no Subscriber. O item fica em `PENDENTE_CORRECAO`.

Antes de mudar para `true`, confira permissões, chaves primárias publicadas, filtros de artigo e o volume das tabelas. O worker lê os conjuntos completos das tabelas divergentes e compara por chave primária. Tabelas muito grandes pedem uma janela controlada.

## Pré-requisitos

- Replicação transacional configurada e ativa.
- SQL Server 2017 ou superior (`STRING_AGG` entra na descoberta e na validação).
- SQL Server Agent em execução nas instâncias.
- Permissão `sysadmin` durante a instalação.
- A conta de `WorkerLogin` existente no Publisher e nos Subscribers, com conectividade entre as instâncias e acesso às tabelas publicadas e assinadas.
- PowerShell disponível para o subsystem do SQL Agent.
