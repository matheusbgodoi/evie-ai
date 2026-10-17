# Validação de timeout do processo TTS

O teste de integração usa o adaptador OmniVoice e o executor de processos reais, com um executável sintético local. Não carrega pesos, áudio pessoal, credenciais ou rede.

## Contrato observado

- A configuração continua com timeout de **0,5 s** e tolerância de encerramento de **0,05 s**.
- Um handler real de SIGTERM grava relógios monotônicos do próprio processo, antes de aguardar o descendente. A asserção exige sinal recebido em **menos de 2 s**; recibo ausente ou inválido falha explicitamente.
- O handler do caso medido não sinaliza o descendente. O teste verifica que o grupo de processos realmente o encerrou, além de exigir `.timedOut` e remoção dos arquivos temporários.
- A variante com consumidor atrasado verifica o descendente encerrado antes de aguardar mais 2,1 s para consumir o resultado. O limite do processo permanece o mesmo.
- O aquecimento é separado e encerra seu próprio descendente. O teardown de falha só encerra o PID registrado se a linha de comando ainda identificar a pasta exclusiva da fixture e o código sintético esperado.

Execute com `Scripts/test --core-only --filter OmniVoiceBatchTTSAdapterTests`.

## Diagnóstico da falha de CI

A execução original registrou 5,406 s no teste e aproximadamente 5,073 s ao redor do `await synthesize`. Somente a expectativa de duração desse `await` falhou; as expectativas de timeout, descendente encerrado e limpeza passaram. Outros testes independentes terminaram simultaneamente após cerca de 4,1 s. Isso sustenta a hipótese de atraso de escalonamento na VM, mas o teste antigo não registrava o instante de entrega do sinal e não permite afirmar esse instante retrospectivamente.

O executor usa temporizadores GCD para sinalizar o grupo e reap fora do MainActor. Medir toda a espera Swift também incluía admissão no actor, preparação e retomada do consumidor. O novo recibo distingue esse tempo da entrega real de SIGTERM, sem aumentar os limites. A segunda execução de CI mostrou que atribuir a falha exclusivamente ao consumidor atrasado era insuficiente: o próprio handler recebeu o sinal após **3,728272792 s**, e outra variante não produziu recibo no prazo. Portanto também havia uma falha real do deadline do processo sob contenção.

Um controle negativo standalone usando o script exato do teste confirmou que sinalizar somente o pai deixa o descendente ativo. Sinalizar o grupo encerra e reap o descendente. O aquecimento separado também foi validado. A primeira versão intermediária da fixture revelou reentrância de `subprocess.wait()` no handler; o corpo principal passou a usar `signal.pause()`, ficando o reap exclusivamente no handler.

## Evidência executada

Em 17/10/2026, a execução focada combinada de TTS, leitura documental e recuperação passou **49 testes em 4 suítes, em 2,819 s**, incluindo as duas variantes de timeout. As asserções de sinal em menos de 2 s, descendente encerrado, `.timedOut` e limpeza passaram. A variante atrasada prolonga propositalmente o tempo total da suíte; esse total não representa a vida do processo. Strict lint do arquivo Swift e `git diff --check` também passaram. Essa rodada local inicial ainda não incluía contenção forçada e não descartava a falha posteriormente demonstrada na segunda execução de CI.

## Regressão de contenção e correção do executor

Uma medição standalone colocou 20 workers globais `userInitiated` sob carga de CPU finita de três segundos. Na mesma execução, o timer de 0,5 s na fila global `utility` só executou após **3,009954625 s**; uma fila serial própria `userInitiated` executou após **0,501880958 s**. Isso reproduziu a inversão de prioridade que pode atrasar o controle do processo enquanto trabalhos de inferência de maior prioridade ocupam os workers compartilhados.

O teste de processo real passou a criar a mesma contenção depois que o descendente está vivo, exigindo que ela comece antes de haver recibo de SIGTERM. O limite continua sendo menos de dois segundos medidos pelo handler; não há aumento de timeout, tolerância ou retries. Antes da correção de produção, essa regressão falhou com **3,0404745 s**, mantendo as demais expectativas de grupo encerrado, `.timedOut` e limpeza.

A correção no `SecureProcessRunner` move somente os callbacks de timeout/SIGTERM e escalonamento para SIGKILL para uma fila serial dedicada com QoS `userInitiated`. Seus callbacks não fazem espera, escrita em stdin ou reap; essas operações continuam fora dela. Retenção, locks, grupo de processos, cancelamento e limites permanecem com o contrato anterior. Isso evita depender da fila global de menor prioridade para cumprir o deadline; não constitui garantia de tempo real sob qualquer escalonamento do kernel.

Depois dessa alteração, os nove testes da suíte TTS passaram em **3,133 s**, incluindo contenção real e as duas variantes de consumidor. O observador da variante atrasada também aguarda a criação do descendente antes de iniciar a espera pelo recibo, para separar admissão no Task da vida do processo. Um recibo ausente continua sendo falha explícita. A execução focada final, após esse ajuste do observador, passou os nove testes novamente em **3,150 s**.
