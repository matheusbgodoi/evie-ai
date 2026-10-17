# Validação integrada do modo de pesquisa

Os diagnósticos `--research-validation` e `--research-agent-validation` são
separados da sessão de pesquisa normal. Eles exercitam captura, transporte real
do modelo, clipboard, AX e eventos do executor num aplicativo nativo descartável.
O primeiro usa ações determinadas pelo diagnóstico; o segundo pede ao modelo
que planeje as ações pelo laço de ferramentas real. Nenhum remove confirmações
da política ou inicia uma sessão invisível.

## Execução

Compile o app Evie pelo fluxo normal (`Scripts/evie-app build`). Compile a
fixture, que não tem rede, banco nem documentos do usuário:

```zsh
Scripts/research-validation
```

O script constrói a fixture, abre uma instância de diagnóstico do bundle em
`.build/release/Evie.app` e espera até 180 segundos pelo relatório novo. Aceita
outro caminho de bundle como argumento e devolve código de saída diferente de
zero em falha ou timeout. Não instala a Evie nem encerra sua instância normal.
Depois do relatório, remove apenas o bundle temporário da fixture que criou.

O processo de Evie usado precisa já ter Acessibilidade, envio de eventos e
Gravação de Tela. O diagnóstico apenas consulta essas permissões; não abre
Ajustes nem pede permissões. É necessário modo agente habilitado. Não use o
atalho enquanto o diagnóstico executa e mantenha a fixture na frente. O
resultado fica em `~/Library/Logs/Evie/research-validation.log`.

Para executar o método opcional com planejamento do agente:

```zsh
Scripts/research-validation --agent
```

O argumento opcional de bundle continua disponível depois de `--agent`. Para
esse ensaio, selecione como preferido um perfil PC com suporte a modo agente.
Esse modo usa `--research-agent-validation` e grava um relatório distinto em
`~/Library/Logs/Evie/research-agent-validation.log`. O prazo externo continua
180 segundos; não há aumento de retries, tempo ou orçamento para obter sucesso.

## Método padrão: resposta visual e ações determinadas pelo diagnóstico

1. O app de teste é lançado pelo diagnóstico, num processo próprio, com campo
   vazio e alternativas para a pergunta sintética `17 × 4`.
2. O indicador de captura é mostrado pelo observador real. ScreenCaptureKit
   captura exclusivamente a janela da fixture identificada por PID e bundle;
   nenhum screenshot é salvo. Outra janela sobreposta não entra nessa captura.
3. O cliente real envia a imagem ao perfil preferido configurado. Raciocínio
   é desligado apenas nessa chamada. Nenhuma ferramenta ou histórico acompanha
   o pedido de resposta numérica.
4. A resposta do modelo passa pelo broker e executor reais para um pasteboard
   com nome exclusivo. O diagnóstico lê esse pasteboard de volta. O valor
   fornecido às ações seguintes é essa resposta, nunca o valor do oráculo.
5. O executor clica no campo da fixture e o preenche pela rota AX. O texto é
   lido de volta pela AX. Em seguida clica na alternativa cujo valor corresponde
   ao texto devolvido pelo modelo.
6. O processo da fixture informa o campo e a alternativa selecionada num JSON
   temporário, validado por nonce e PID. O diagnóstico confere ambos e termina
   somente o processo que lançou, revoga o broker e devolve o foco.

Há um oráculo que exige `68`; uma resposta incorreta encerra o ensaio antes
das ações no campo. Esse oráculo mede o acerto, não resolve a pergunta nem
fornece texto ao executor. O clipboard geral não é lido ou escrito. A escrita
usa AX, portanto este ensaio não comprova a rota `⌘V` em outro aplicativo;
`--cu-selftest` continua sendo a verificação das três rotas de digitação.

O diagnóstico recusa uma fixture já aberta e interrompe se o foco sair dela.
Todas as ações passam pela política existente. Se ela pedir uma confirmação,
esse método padrão falha; não há chamada de autoaprovação. O diagnóstico não aceita abrir
outro aplicativo, executar instruções presentes na imagem nem submeter um
formulário.

## Método opcional: planejamento real do agente

O modo `--agent` compartilha a mesma fixture offline, captura exclusiva por
PID, permissões, broker e executor. O objetivo usa exatamente
`ResearchModeController.agentGoal`, acrescentando somente que a janela de teste
deve ser resolvida, o campo deve conter apenas o número e a alternativa
correspondente deve ser selecionada. O resultado esperado não é informado ao
modelo nem transformado em uma sequência de ações pelo diagnóstico.

`ComputerUseSession` e `EvieAgentLoop.runComputerUse` fazem as observações e
chamadas reais de ferramentas. O modelo escolhe ferramentas, alvos AX, valores
e ordem das ações, vinculando cada chamada ao `observation_id` fornecido pelo
observador. O raciocínio usa o mesmo
`computerStep` da produção, sem forçar o modo desligado do método padrão.
O grant continua sendo `.researchShortcut`, com autorização explícita apenas
para escrita de resposta no pasteboard nomeado. A digitação usa AX sem fallback
para o clipboard geral.

Cada confirmação solicitada é contada e respondida com `false`; nenhuma é
aprovada automaticamente. Diferentemente do método padrão, o laço pode receber
essa recusa e escolher outra ação permitida. Isso não amplia sua política nem
permite concluir ou enviar formulários. Todas as observações e ações são
envolvidas por guardas do PID/bundle da fixture antes e depois de awaits; os
pedidos de observação permanecem limitados à janela da fixture.

Sucesso exige que o agente termine com `finish(success)`, tenha executado pelo
menos uma ação real e que sua contagem corresponda à contagem do executor.
Depois disso, a leitura independente do JSON da fixture exige nonce e PID
corretos, campo `68` e seleção `B) 68`; o pasteboard exclusivo precisa conter o
mesmo número. O oráculo só avalia esse estado final e nunca é fornecido ao
planejador. A limpeza revoga o mesmo grant, encerra somente a fixture lançada
pelo diagnóstico e restaura o foco.

**Estado do novo método em 2026-10-17:** fonte e documentação adicionados;
execução real com o PC ainda não registrada neste checkpoint, enquanto a
autorização legítima do Chaveiro aguarda o proprietário. Os resultados antigos
abaixo são do método padrão e não demonstram planejamento autônomo. O relatório
novo só poderá ser marcado como aprovado depois de executar o bundle integrado.

## Limites e estabilidade

Ambos são ensaios controlados, sem planejamento livre em sites arbitrários.
No método padrão, o identificador AX do campo e a comparação do valor da
alternativa são escolhidos pelo diagnóstico após a resposta visual. No método
opcional, essas decisões cabem ao modelo, limitadas à fixture e à política
existente. Acerto neste caso não prova compreensão geral nem humanização.

Os testes `EvieResearchStreamTests` exercitam cancelamento durante a espera
do modelo, falha realista do stream antes de completar e rejeição de mensagem
com papel incorreto. A sessão e o broker também têm testes de concorrência,
expiração e revogação em `EvieResearchTests`.

A fixture não fica instalada, não cria serviço, não tem timer recorrente e
não usa CPU após sair. O modo pesquisa normal também não captura em laço: seu
custo ocioso é uma sessão em memória e uma tarefa suspensa para a expiração.
Não se atribui um valor de energia ou bateria sem medição.

As medições executadas devem ser registradas com data, hardware, versão,
modelo, raciocínio, resolução e resultado. O log contém apenas dados sintéticos
do ensaio e latências. Não exporte configurações nem credenciais.

## Execuções registradas

Em 2026-10-16, Apple M5, 24 GB, macOS 27.2 (26B5086k), Xcode 27.1 (27A9275):

- `Scripts/research-fixture`: compilação Swift 6 com avisos tratados como erros
  e assinatura ad hoc da fixture passaram.
- `swift build -Xswiftc -warnings-as-errors`: pacote completo passou em 9,64 s.
- `Scripts/test --filter EvieResearchStreamTests`: 3 testes passaram em 0,002 s,
  após compilação de 28,29 s.
- `zsh -n Scripts/research-fixture Scripts/research-validation` e
  `git diff --check`: passaram.
- `Scripts/evie-app build`: checkpoint de produção passou em 210,54 s, com
  avisos tratados como erros, assinatura estável e metadados de 3 App Intents
  e 3 App Shortcuts extraídos e validados. Esse checkpoint antecedeu as travas
  adicionais de preenchimento; a versão final deve repetir o ensaio abaixo.
- `Scripts/research-validation`, no bundle assinado aberto por Launch Services:
  captura exclusiva da fixture de 722 × 472; `qwen-daily`, raciocínio desligado;
  resposta `68` em 40,277050375 s; clipboard nomeado lido de volta; campo `68`
  confirmado pela AX e pelo processo da fixture; alternativa `B) 68` confirmada
  pelo processo. Foram 4 ações e nenhuma confirmação automática. A fixture foi
  encerrada e o foco restaurado. Total: 43,743050084 s. Resultado: passou.
- `--native-apple-check`, no mesmo bundle por Launch Services: `success: true`,
  três `perform()` corretos, guardas de início/interface ocupada/Unicode e
  metadados completos. Foundation Models estava disponível nesse Mac. Não é um
  teste de reconhecimento de voz da Siri nem de descoberta no app Atalhos.

A validação web e o método de pin de DNS estão em [WEB_SEARCH](WEB_SEARCH.md)
e [ADR 0027](adr/0027-pinned-public-web-transport.md). A rodada inicial encontrou
uma diferença real: Darwin aceita octetos IPv4 com zero inicial como decimais,
enquanto o transporte pode interpretá-los como octais. A regressão de
`0177.0.0.1` falhou antes da exigência de representação canônica e passou depois.
O servidor loopback comprovou pin, POST, ausência de cookies entre processos,
limite em resposta chunked sem Content-Length e cancelamento real. A primeira
rodada verde teve 10 testes em 0,629 s; os casos adicionais de DNS e gzip são
incluídos na rodada final abaixo.

Em 2026-10-17, no mesmo hardware e toolchain:

- Suíte integrada de 14 testes web e 9 testes de compactação: 23 testes em
  3 suites passaram em 4,238 s, com compilação completa de EvieShell e avisos
  tratados como erros. Inclui cancelamento/prazo do DNS, gzip legível, expansão
  de gzip acima do teto, IP pin real, chunked sem Content-Length e cancelamento
  do processo HTTP real.
- `.build/debug/evie-shell --web-check 'Swift.org getting started'`: 6 resultados
  em 0,919890417 s; leitura de 3.255 caracteres de
  `https://www.swift.org/getting-started/`; 10 destinos proibidos recusados;
  total de 1,899960417 s. Resultado: passou.
- A consulta `Apple Swift documentation` encontrou 6 resultados em
  0,984423583 s, mas o primeiro era a documentação SPA da Apple, sem corpo
  textual que o leitor possa extrair sem JavaScript. Essa leitura foi recusada
  como `notReadable`, sem afirmar que a página foi lida. O primeiro probe
  também identificou gzip vindo do servidor apesar de `Accept-Encoding:
  identity`; o transporte foi corrigido para decodificação em stream com o
  limite aplicado depois dela, comprovado pelos testes de gzip acima.
- Auditoria de imagens candidatas à publicação: Vision OCR em modo preciso
  sobre 20 PNG/JPEG existentes, rastreados e novos não ignorados. Comparação
  normalizada com 3 padrões derivados da configuração externa do titular,
  conservados apenas em memória. Nenhum arquivo correspondente e nenhum erro
  de OCR. Não houve captura do desktop, impressão de padrões nem gravação do
  texto reconhecido. A auditoria OCR complementa a varredura de texto/binário;
  não é uma prova de ausência de todo dado possível numa imagem.
