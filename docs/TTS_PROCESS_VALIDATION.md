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

O executor usa temporizadores GCD para sinalizar o grupo e reap fora do MainActor. Medir toda a espera Swift também incluía admissão no actor, preparação e retomada do consumidor. O novo recibo distingue esse tempo da entrega real de SIGTERM, sem aumentar os limites nem alterar produção.

Um controle negativo standalone usando o script exato do teste confirmou que sinalizar somente o pai deixa o descendente ativo. Sinalizar o grupo encerra e reap o descendente. O aquecimento separado também foi validado. A primeira versão intermediária da fixture revelou reentrância de `subprocess.wait()` no handler; o corpo principal passou a usar `signal.pause()`, ficando o reap exclusivamente no handler.

## Evidência executada

Em 17/10/2026, a execução focada combinada de TTS, leitura documental e recuperação passou **49 testes em 4 suítes, em 2,819 s**, incluindo as duas variantes de timeout. As asserções de sinal em menos de 2 s, descendente encerrado, `.timedOut` e limpeza passaram. A variante atrasada prolonga propositalmente o tempo total da suíte; esse total não representa a vida do processo. Strict lint do arquivo Swift e `git diff --check` também passaram. Não houve mudança no adaptador ou executor de produção para esta correção do método de medição.
