# Integrações Apple nativas

A instalação local usa o app **Atalhos** e o esquema público `evie`, com a
assinatura estável já utilizada pela Evie. Não chama serviços privados da Siri,
não extrai suas vozes e não usa seu motor de pesquisa. A Siri pode executar os
atalhos pelo nome quando estiver habilitada e disponível no idioma do sistema;
o reconhecimento de uma frase falada é uma fronteira distinta da execução pelo
app Atalhos.

## Três atalhos públicos

| Atalho | Ações no app Atalhos | Resultado |
| --- | --- | --- |
| Abrir Evie | URL `evie://open` → Abrir URLs | Abre o campo de conversa. |
| Preparar pergunta na Evie | Pedir Entrada → Codificar URL → Texto → Abrir URLs | Pede uma pergunta e prepara um rascunho para revisão. |
| Olhar tela com a Evie | URL `evie://capture` → Abrir URLs | Abre uma confirmação visível antes de solicitar a captura. |

No atalho de pergunta, a ação **Texto** contém `evie://prepare?text=` seguida da
variável mágica **Texto do URL Codificado**, saída de **Codificar URL**. A ação
**Abrir URLs** recebe esse texto. Codificar a entrada preserva acentos, espaços,
`&` e emoji sem transformá-los em parâmetros adicionais. Nenhuma ação de shell,
AppleScript ou API privada é necessária. É possível atribuir uma tecla ao atalho
nas opções do próprio app Atalhos.

Preparar uma pergunta não a envia ao modelo e não substitui um rascunho existente.
Abrir uma URL não concede controle do computador, não aceita aprovações, não
escreve arquivos e não começa inferência. Interações em andamento são recusadas.
A URL de captura não fotografa a tela por conta própria: a confirmação explícita
usa o caminho normal com indicador e a permissão de gravação do macOS. Cancelar,
fechar, parar, suspender ou desativar a sessão revoga essa confirmação pendente.

A entrada externa aceita somente as três rotas documentadas. A pergunta admite
um único parâmetro `text`, até 8.000 caracteres Unicode; a URL codificada inteira
é limitada a um MiB. Credenciais, porta, caminho, fragmento, parâmetros extras ou
duplicados são recusados. Esses limites são da integração, não do contexto do
modelo. O esquema URL é público: não contém segredos nem é um canal autenticado.

## Por que a instalação local usa URLs

O candidato anterior expunha três App Intents e três App Shortcuts. A descoberta
real no app Atalhos passou; a invocação real de **Abrir Evie**, pelo editor e pela
CLI pública `shortcuts run`, falhou com `LinkDaemon.ProcessRegistry.Errors`
error 0. O log do sistema identificou `Unable to get teamId`. A assinatura local
estável não tem TeamIdentifier e este Mac não possuía uma identidade válida
Apple Development ou Developer ID. O diagnóstico que chamava `perform()` dentro
do processo não havia exercitado essa fronteira.

O modo padrão agora é `EVIE_NATIVE_APPLE_MODE=public-urls`. O bundle registra
`CFBundleURLTypes` e recebe URLs pela API pública
[`NSApplicationDelegate.application(_:open:)`](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:open:)).
Os App Intents diretos e seu provider ficam fora dessa compilação e seus
metadados são removidos; a instalação não anuncia ações conhecidas por falhar.
Não foi fabricado Team ID nem alterada a identidade estável para contornar o
sistema. A decisão e suas fronteiras estão na
[ADR 0029](adr/0029-native-shortcuts-with-stable-local-signing.md).

O modo opcional `app-intents`, compilado com `EVIE_DIRECT_APP_INTENTS`, continua
exigindo uma assinatura Apple legítima e TeamIdentifier não vazio. Nesse modo,
`Scripts/evie-native-metadata` extrai e confere três ações e três App Shortcuts
antes da assinatura; build e instalação verificam a identidade real e o modo.
Isso é uma opção de distribuição, não um requisito dos atalhos públicos acima.

## O que a Evie aproveita do sistema

- AppKit/SwiftUI, materiais nativos e acessibilidade na interface.
- SpeechAnalyzer para transcrição e AVFoundation para áudio e vozes públicas.
  A voz **Luciana aprimorada**, pt-BR, foi instalada pela interface pública dos
  Ajustes: o catálogo real passou a ter dez vozes utilizáveis, uma aprimorada.
  A voz global do sistema foi preservada. Evidência: [NATIVE_VOICE](NATIVE_VOICE.md).
- Vision para OCR e consulta à disponibilidade de Foundation Models.
- Automação pública de Mail e Calendário nos adaptadores existentes.
- Atalhos com ações públicas de entrada, codificação e abertura de URLs.

`SystemLanguageModel.default.availability` é consultado sem gerar texto, baixar
modelos ou ativar Apple Intelligence. A disponibilidade depende do hardware e dos
ajustes/downloads gerenciados pelo macOS. O modelo do sistema não substitui o PC
ou o LensVLM. A busca web continua no adaptador próprio da Evie.

## Permissões e credenciais

Habilitar capacidades na Evie não concede permissões do macOS. Os pedidos reais
pelo guia da aplicação e pelos diálogos públicos foram exercitados; a auditoria
instalada confirmou os cinco consentimentos principais e a automação de Mail e
Calendário quando os aplicativos de destino estavam abertos. Um código de alvo
fechado não deve ser interpretado como consentimento negado. Nenhuma mensagem ou
evento foi consultado para conceder essas permissões.

O pedido legítimo do Chaveiro para a credencial do modelo é separado. Somente o
proprietário pode digitar sua senha diretamente no diálogo do macOS; a Evie não
lê nem substitui essa senha. Os atalhos de abertura e rascunho não enviam a
pergunta nem exigem uma resposta do modelo para serem validados.

## Verificação e limites da evidência

`--native-apple-check` é um diagnóstico isolado. No modo URL chama o parser e o
encaminhamento reais para as três rotas, com destino de interface substituído
somente nesse processo. Confere modo do bundle, registro do esquema, ausência de
metadados diretos, inicialização incompleta, interface ocupada, pergunta vazia e
limite Unicode. Não captura a tela, não gera uma resposta e não comprova, sozinho,
a invocação pelo app Atalhos. No modo direto exige assinatura Apple/metadados e
exercita os respectivos `perform()`.

O ciclo da confirmação de captura tem regressão vermelho → verde com o
controlador real e callback sintético: a implementação anterior admitia uma
confirmação obsoleta após suspensão; a atual a revoga sincronicamente. O teste
não suspende o Mac nem captura sua tela. Método:
[NATIVE_CAPTURE_VALIDATION](NATIVE_CAPTURE_VALIDATION.md).

### Invocação real pelo Atalhos

Em 2026-10-17, no macOS 27.2, as três rotinas foram construídas no próprio app
Atalhos com as ações públicas acima e invocadas de verdade pela CLI pública
`shortcuts run`, após a instalação do bundle URL. Executável validado:
`129d1878a0e0b948a35c26ee9e7b25ad989c0152b7102ab875fa57391a34cb7a`.

| Fronteira real | Resultado observado |
| --- | --- |
| Abrir Evie | Saída 0; após fechar a interface com Escape, a rotina reabriu o campo da Evie no mesmo processo instalado. |
| Pergunta dinâmica | Saída 0; Pedir Entrada → Codificar URL preservou exatamente `Validação Evie A&B 🧪 7341` no rascunho. Nenhuma pergunta foi enviada. |
| Captura solicitada | Saída 0; abriu a janela de revisão com os IDs de confirmar/cancelar. Cancelar fechou a revisão; nenhum print foi tirado nesse teste. |

O macOS apresentou consentimentos públicos do Atalhos específicos para abrir a
Evie e retornar a saída das próprias rotinas; foram concedidos por esses diálogos.
A primeira espera na ação Abrir URLs não era falha do delegate: a solicitação
estava no processo público de interface do Atalhos. O parser/diagnóstico isolado
e a descoberta anterior não foram usados como substitutos desta execução.

O rascunho sintético foi apagado pelo caminho real de edição e sua ausência foi
verificada após fechar e reabrir a interface. Os três editores próprios foram
fechados; a Evie permaneceu aberta em segundo plano, sem revisão pendente.
A biblioteca terminou com os dez atalhos originais preservados e os três
canônicos, sem atalhos temporários de QA. O atalho antigo que demonstrou a falha
de App Intents foi removido. Uma inspeção posterior do catálogo público de
ações, com busca “Evie”, retornou zero linhas: as ações diretas antigas já não
eram anunciadas. Os três atalhos canônicos continuam na biblioteca e usam as
ações públicas de URL, independentemente desse catálogo.

O diálogo de credencial do proprietário permaneceu intocado. Por privacidade,
a validação de captura parou na revisão/cancelamento; ela não afirma ter
fotografado uma tela nesse teste. O caminho de captura normal possui validação
própria. Tampouco houve teste de frase falada à Siri: a execução comprovada aqui
é pelo sistema Atalhos, sem depender de reconhecimento de voz ou inferência.

Referências públicas: [variáveis no Atalhos](https://support.apple.com/guide/shortcuts-mac/apdd02c2780c/mac),
[AppIntent](https://developer.apple.com/documentation/appintents/appintent),
[execução de App Intents](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents),
[App Shortcuts](https://developer.apple.com/videos/play/wwdc2024/10210/).
