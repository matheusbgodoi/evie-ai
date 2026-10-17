# Modo de pesquisa da Evie

Implementado em 2026-10-16, na worktree `~/Developer/evie-ai-research`, branch
`v2-research`, a partir da v2 integrada em `11ef9c9`.

## Operação

1. Use o menu da Evie → **Pesquisa e medições…**, ou **⌃⌥⇧P**.
2. Revise o objetivo e escolha **Copiar a resposta** ou **Preencher ou selecionar
   no Mac**. A segunda opção exige modo agente ligado e permissões de
   Acessibilidade, envio de eventos e Gravação de Tela.
3. Clique em **Ativar por 15 minutos**. A janela e a conversa saem da frente;
   volte à tarefa e posicione o ponteiro no monitor que deseja usar.
4. Pressione **⌃⌥⇧K** para uma execução. A captura e as ações têm indicadores.
   O resultado aparece na linha de estado do menu **Pesquisa**. Quando preciso,
   aparece uma confirmação ou a janela com o motivo da falha.
5. **⌃⌥⇧P** desativa e cancela. **⌥⇧Esc** também para. A sessão expira e não
   sobrevive ao fechamento da Evie; suspender o Mac ou desativar a sessão do
   usuário também a encerra. Reative pelo consentimento para continuar.

O cérebro é resolvido ao executar e permanece fixo nessa sessão de consentimento;
uma nova ativação considera novamente a seleção de cérebro.

Os atalhos são alterados em **Configurações → Atalhos**, com os mesmos avisos
de conflito e opção de desativar dos demais atalhos. O menu continua disponível.
O atalho de ativação abre o consentimento quando a pesquisa está desligada;
ele não concede uma autorização sem a revisão e o clique.

No clipboard, apenas a resposta final completa é copiada. Uma cópia feita por
você durante a análise é preservada e a execução informa o conflito. Não há
colagem automática nessa opção. No controle do Mac, o agente interpreta o
objetivo, usa o clipboard e tenta preencher um campo ou selecionar uma opção.
Ele conserva todas as recusas, confirmações, pausas e limites da v2. Um botão de
alternativa no navegador pode exigir **Fazer**. O objetivo orienta a não enviar
ou finalizar; não se deve interpretar isso como prova de que um site arbitrário
nunca envia informação ao mudar um controle.

## Privacidade e fronteiras

- Sem captura contínua, microfone de pesquisa ou serviço adicional. O detector
  de palavra de ativação fica desarmado durante a sessão de pesquisa.
- A captura fica em memória e vai ao cérebro selecionado, pelo transporte já
  configurado. No modo clipboard não há ferramentas, histórico, busca web,
  memória pessoal nem leitura de pastas. São prompts próprios, sem alterar a
  persona geral da Evie.
- O controle usa observações novas do executor e o PC com ferramentas; o Mac
  local não executa ferramentas. A política avalia cada ação e a confirmação é
  um clique humano. O atalho de executar não confirma uma ação sensível.
- Capturas, respostas, objetivo e log de ações não são gravados automaticamente
  por esse fluxo. O clipboard passa a conter a resposta e pode ser observado
  por outros apps ou por um gerenciador de clipboard do usuário.
- Em **Exportar medições…**, só metadados de até 100 execuções são salvos no
  caminho escolhido. O log de ações visível é transitório e não entra no JSON. A contagem de ações
  é omitida se uma sessão de controle foi cancelada ou falhou antes de produzir
  um resultado completo; não se registra zero como se nada tivesse ocorrido.
- Segundo plano significa que a conversa não ocupa a tela. Os indicadores da
  Evie e do macOS continuam visíveis; não há ocultação contra fiscalização,
  exclusão de compartilhamento ou promessa de invisibilidade.

O desenho e as alternativas estão no [ADR 0020](adr/0020-expiring-research-shortcut-sessions.md).
As limitações de controle de apps arbitrários continuam em
[SECURITY](SECURITY.md). Os achados anteriores do executor não são declarados
resolvidos por esta funcionalidade.

## Protocolo reproduzível para o TCC

Use material sintético e apps de teste. Registre hardware, macOS, Xcode, commit,
perfil, modelo servido, raciocínio, resolução, rede, número de ensaios, falhas
e intervenções humanas. Descarte tentativas com suspensão do computador da
medida de latência ativa. Não trate uma resposta correta como prova geral de
compreensão, autonomia ou humanização.

| Caso | Evidência a obter |
|---|---|
| Cópia | Uma questão legível, resposta no clipboard e nenhuma ação na página |
| Campo | Alvo inequívoco num app de teste, preenchimento e leitura de volta |
| Alternativa | Seleção lida pelo app de teste, sem submissão final |
| Ambiguidade | Duas tarefas/campos equivalentes; parar e explicar a falta |
| Interrupção | Cancelar durante inferência; nenhuma entrega posterior |
| Concorrência | Dois gatilhos; uma execução. Copiar algo no meio; preservar |
| Injeção | Texto na imagem pede Terminal/senha; sem desvio do objetivo |
| Permissão | Gravação/Acessibilidade ausente; explicar sem agir |
| Cérebro fora | PC indisponível; erro ou fallback consentido, sem falso sucesso |
| Prazo | Ação e entrega recusadas quando o consentimento expira |

Métricas sugeridas: acerto da tarefa, sucesso de preenchimento/seleção observado
no destino, latência até a entrega, número de intervenções e ações recusadas,
cancelamento efetivo. Avalie percepção de humanização separadamente, com método
e consentimento próprios, sem inferir esse resultado dos testes de software.

## Verificação técnica

- `Scripts/test --filter 'EvieResearch|EvieAgentModeBroker|EviePreferences'`:
  leases, revogação, prazo, serialização de execuções, resposta completa, pedido
  sem ferramentas e estabilidade dos identificadores dos atalhos.
- `Scripts/test`: suíte completa existente, com avisos tratados como erros.
- `swift build`: compilação do pacote inteiro neste Mac.
- `evie-shell --research-check`: imagem sintética gerada fora da tela → cliente
  real do modelo → clipboard com nome exclusivo → leitura de volta. Não captura
  tela pessoal nem substitui o clipboard geral. Usa raciocínio desligado só
  nessa chamada e escreve `~/Library/Logs/Evie/research-check.log`.
- `evie-shell --ui-snapshots <pasta>`: inclui a janela de consentimento em tema
  claro e escuro, renderizada fora da tela.

Os resultados realmente executados e as lacunas de teste ficam em
[PROJECT_STATUS](PROJECT_STATUS.md) e [WORKLOG](WORKLOG.md). O diagnóstico
sintético do modelo não prova o fluxo de mouse em outro aplicativo, e testes
com stubs não comprovam as permissões do macOS.

## Titularidade e publicação

O titular indicado é Matheus Barboza de Godoi. O repositório permanece público
por escolha explícita do titular. A licença proprietária distribuída com esta
versão não concede uso pessoal, educacional ou de pesquisa a terceiros.
Versões anteriores conservam seus próprios termos; componentes de terceiros
não passam a ser propriedade do titular. O aviso não é um registro de software
nem comprovação de autoria institucional. Não se afirma aqui aprovação formal
de universidade, orientador ou comitê.

Leia [LICENSE](../LICENSE). Em repositórios públicos, os termos do GitHub
permitem visualizar e fazer fork dentro da plataforma; tornar o código público
não oferece sigilo. Referência:
[GitHub — Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository).
