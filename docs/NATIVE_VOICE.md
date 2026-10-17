# Voz e chamada nativas

Implementação de 2026-10-16; validação atualizada em 2026-10-17. A transcrição usa `SpeechAnalyzer` e
`SpeechTranscriber`, no macOS, em português brasileiro. A fala nativa usa
`AVSpeechSynthesizer`; escolher uma voz do sistema não inicia OmniVoice,
Whisper, Python ou um modelo adicional pertencente à Evie.

## Escolher a voz

Em **Ajustes › Voz**, escolha **Automática · melhor voz nativa instalada**, ou
uma voz específica na seção **Do sistema**. A escolha automática considera a
qualidade que o macOS informa, privilegiando premium e aprimorada e deixando
vozes de personagem depois das vozes convencionais. A etiqueta diz **padrão**,
**aprimorada** ou **premium**, sem prometer naturalidade não medida.

**Gerenciar vozes do macOS…** abre a configuração nativa de acessibilidade,
onde a Apple oferece downloads de vozes. A lista se atualiza pela notificação
`availableVoicesDidChangeNotification`, sem polling. Uma voz anteriormente
selecionada que deixou de estar disponível é indicada no seletor, e a fala usa
uma alternativa nativa disponível.

As vozes clonadas previamente criadas continuam preservadas e opcionais. Seus
pesos, referências, ambiente Python e arquivos de configuração não foram
apagados. A transcrição cotidiana e a nova calibração não dependem do Whisper
usado pelo motor de clonagem para preparar referências antigas.

## O que foi verificado sobre Siri

Uma lista de vozes não comprova que um app terceiro possa usar cada uma.
Nesta máquina, o probe executado fora de um bundle via terminal encontrou os
identificadores públicos de Sandra e Nando. O mesmo probe, em um bundle assinado
com a identidade de desenvolvimento da Evie, retornou `nil` ao instanciar ambas.
Por isso elas não são oferecidas como vozes utilizáveis no aplicativo.

No checkpoint inicial de 2026-10-16, em um bundle de teste assinado, a voz
pública Luciana padrão produziu **62.236 frames**,
**2,82 segundos** de áudio para uma frase sintética, em cerca de **0,62–0,75 s**.
O áudio foi sintetizado em memória e não foi reproduzido nem salvo. Ambiente:
Apple M5, 24 GB, macOS 27.2 (26B5086k), Xcode 27.1 (27A9275), SDK macOS 27.0.
Naquele teste inicial não havia voz pública aprimorada/premium pt-BR utilizável
instalada. Esse estado foi superado pela instalação pública descrita abaixo.
Esses números são observações dessa instalação, não garantias de latência ou
qualidade para outros dispositivos.

Voz Pessoal da Apple é uma capacidade distinta: a autorização não cria uma
voz e não transforma cinco chamadas em uma voz sintética. Ela não é oferecida
neste seletor, que depende de buffers de áudio para medir a amplitude real da
fala. A implementação não chama APIs privadas, copia assets da Siri nem
contorna restrições de voz do macOS.

## Voz aprimorada instalada e verificada (2026-10-17)

A **Luciana (Aprimorada)** foi baixada pelo catálogo público em **Ajustes do
Sistema › Acessibilidade › Leitura e Fala › informações de Voz do sistema ›
Português › Voz**. O catálogo mostrava download de 38,3 MB e, depois de concluir,
uso de 42,7 MB. Não foi usada API privada de download, extração de assets Siri,
edição do TCC ou criação de Voz Pessoal. A voz global do sistema foi preservada.
A Apple descreve esse fluxo em [alterar e adicionar vozes](https://support.apple.com/pt-br/guide/mac-help/mchlp2290/mac).

O executável do candidato instalado foi verificado novamente com
`--native-voice-check`: **10 vozes públicas pt-BR utilizáveis**, sendo **uma
aprimorada**, e seleção automática de
`com.apple.voice.enhanced.pt-BR.Luciana`. A frase sintética produziu
**58.599 frames**, **2,658 s de áudio** e síntese em **0,291 s**. Síntese,
cancelamento, SpeechAnalyzer e persistência temporária controlada passaram.
A transcrição sintética foi “esta é uma frase de pesquisa”; o nome Evie foi
omitido pelo reconhecedor e `syntheticWakeNameRecognized` permaneceu `false`.
O [relatório sanitizado desse checkpoint](validation/native-voice-enhanced.json)
preserva esses estados, sem converter a amostra em treinamento do proprietário.

Os dois identificadores privados Siri continuaram indisponíveis, e a autorização
de Voz Pessoal continuou negada. A calibração do proprietário estava
`notConfigured`, com zero aliases: baixar uma voz para saída de áudio não faz
as cinco chamadas reais de entrada. Esses resultados são do candidato instalado,
não uma declaração antecipada sobre publicação ou todos os dispositivos.

## Ativação por voz e consumo

A ativação por voz fica **habilitada por padrão por pedido explícito do
proprietário** (ADR 0022), sujeita às permissões reais do macOS. A frase padrão
é “Ei, Evie”; uma calibração válida pode configurar a chamada curta “Evie”.
Habilitar a preferência não cria uma calibração nem identifica o falante.

Quando o ouvinte está armado, ele usa o microfone e o reconhecimento local,
mesmo sem uma conversa aberta. O indicador laranja do macOS continua visível e
há custo de energia. A ausência de animação na marca não significa microfone
fechado. Desativar a chamada ou usar a parada de emergência interrompe a escuta;
o fluxo de pesquisa também a desarma enquanto mantém sua sessão isolada.
Medições finais de consumo e suas condições ficam no relatório integrado, sem
prometer custo ocioso zero ou confundir wake com inferência contínua do LLM.

## Calibrar cinco chamadas de “Evie”

Em **Ajustes › Voz**, clique em **Calibrar cinco chamadas de “Evie”…**.

1. Grave uma chamada dizendo apenas “Evie”, na distância normal de uso.
2. Clique em **Concluir gravação**, ou aguarde o limite de cinco segundos.
3. Confira a transcrição e repita até completar cinco chamadas; **Repetir última**
   permite corrigir uma amostra.
4. Clique em **Salvar calibração** para ativar a chamada “Evie”.

A Evie suspende o ouvinte e a interação cotidiana enquanto a calibração detém
o microfone. Entre as amostras ele fica fechado. Cancelar, o atalho de parada e
encerrar o app param a captura e o reconhecedor antes de liberar a sessão.
Uma preparação atrasada não pode reabrir a captura depois de cancelar.

São aceitas somente transcrições curtas plausíveis da palavra Evie; conversa
alheia não vira uma palavra de ativação. A calibração guarda as variantes
efetivamente observadas mais “Evie”, sem gravar áudio. Os aliases curtos usam
correspondência exata de um novo resultado **final** do reconhecedor, evitando
aceitar um palpite parcial que depois se transforma em “eu vi”. Frases como
“hoje eu vi”, “Steve” e “Evie abre o Terminal” não são chamadas calibradas.
Chame “Evie”, faça uma pausa e depois diga a pergunta quando o microfone abrir.

Isto é calibração textual de reconhecimento, não biometria, identificação do
falante, treinamento da Siri ou adaptação dos pesos do modelo Apple. A API
pública não permite que o app se aproprie do detector dedicado de Siri. O
microfone do ouvinte continua sujeito ao indicador laranja do macOS.

O arquivo `wake-enrollment.json`, ao lado das preferências, tem permissões
`0600`; a pasta tem `0700`. Contém aliases e data, sem áudio ou embeddings. É
validado ao ler, tem limite de 4 KiB e rejeita aliases arbitrários. Se a
preferência não puder ser salva, o registro anterior é restaurado. Alterar a
frase manualmente para outra chamada deixa de usar essa calibração.

## Cancelamento e diagnóstico

`NativeSpeechBufferCollector` aceita cancelamento antes ou depois de instalar a
continuação e a conclui uma única vez. A síntese nativa tem prazo de 20 segundos
por bloco. Parar a fala cancela também a coleta pendente. Uma tarefa antiga não
prefaz outra frase nem encerra uma fala nova depois de ser cancelada.

`--native-voice-check` faz síntese silenciosa real pelo AVFoundation e grava um
relatório JSON em `~/Library/Logs/Evie/native-voice-check.json`. Informa frames,
duração, latência, quantidade de vozes públicas utilizáveis, indisponibilidade
dos dois identificadores Siri verificados, os checks de cancelamento e o estado
da calibração (`notConfigured`, `valid` ou `invalid`). Não abre o microfone,
não grava/reproduz áudio nem solicita permissões. O JSON inclui somente a
transcrição da frase sintética controlada; não registra transcrições pessoais,
nomes de vozes pessoais ou conteúdo de conversas.

O diagnóstico também encaminha os buffers sintéticos ao SpeechAnalyzer e testa
uma calibração de cinco transcrições controladas em uma pasta temporária, apagada
ao terminar. Esse arquivo não substitui a calibração do usuário. Se o pacote
pt-BR ainda não estiver instalado, a verificação explica a dependência;
`--native-voice-check --install-speech-assets` permite instalar o recurso nativo
antes de verificar, com prazo maior para o download.

Esse percurso foi executado em bundle assinado: o pacote pt-BR foi instalado e
a transcrição retornou “Esta é uma frase de pesquisa.”, com os checks de síntese,
cancelamento, análise e persistência temporária aprovados. A palavra Evie no
início dessa amostra sintética não foi transcrita, registrada honestamente por
`syntheticWakeNameRecognized: false`. Isso não foi tratado como calibração da
voz do proprietário; a interface continua exigindo suas cinco chamadas reais.

Os quatro testes `EvieWakeEnrollmentTests` passaram em um pacote SwiftPM
isolado, com warnings-as-errors: variantes observadas, rejeição de amostras
alheias/incompletas, persistência real `0600`, remoção e arquivos forjados ou
excessivos. O diagnóstico não equivale a uma calibração do usuário: cinco
chamadas reais precisam ser gravadas por ele na interface para existir um
registro pessoal válido.

`--wake-lifecycle-check` verifica outro contrato, com o microfone real e uma
permissão já concedida: desarmar durante a preparação assíncrona não pode
religar a escuta; um armamento posterior deve funcionar e desarmar normalmente.
Não lê ou registra transcrições, não salva áudio e não pede permissão. O relatório
contém somente estados e códigos de falha estáticos. Se não observar um armamento
pendente antes da interrupção, registra falha em vez de presumir que testou a corrida.

Em 2026-10-17, no Mac Apple M5, macOS 27.2, SDK 27.0, o mesmo probe assinado com
a identidade da Evie executou vermelho → verde contra o microfone real. Uma cópia
temporária do listener, removendo somente a verificação de geração, retornou
`staleArmResurrected: true`, `pendingArmWasInterrupted: true`, `success: false`.
Com o fonte corrigido, retornou `staleArmResurrected: false`,
`pendingArmWasInterrupted: true`, `normalArmSucceeded: true`,
`disarmedAfterNormalArm: true`, `success: true`. Nenhum fonte de produção foi
alterado para enfraquecer esse teste; a cópia regressiva ficou fora do repositório.

Referências: [qualidade aprimorada](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoicequality/enhanced),
[síntese de fala](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer),
[SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer),
[Voz Pessoal](https://developer.apple.com/videos/play/wwdc2023/10033/).
