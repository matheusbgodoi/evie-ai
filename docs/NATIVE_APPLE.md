# Integrações Apple nativas

Implementado em 2026-10-16 com APIs públicas de App Intents. A Evie oferece ações
próprias ao app Atalhos e às superfícies do sistema que descobrem App Shortcuts,
incluindo Siri. O macOS decide a indexação e disponibilidade dessas superfícies.
Não existe chamada a um backend privado da Siri ou uso do serviço de busca dela.

## Usar

Após instalar a Evie, abra **Atalhos**, crie um atalho e procure por **Evie** nas
ações. Há três ações:

| Ação | Resultado |
| --- | --- |
| Abrir Evie | Abre o campo de conversa. |
| Preparar pergunta na Evie | Preenche um rascunho para revisar e enviar. Recebe texto de outras ações do atalho. |
| Olhar tela com a Evie | Abre a Evie e solicita uma captura da tela sob o ponteiro para a próxima pergunta. |

As frases de App Shortcuts incluem “Abrir Evie”, “Conversar com Evie”, “Preparar
pergunta na Evie” e “Olhar tela com Evie”. O nome da aplicação é um token do
sistema, não uma string de reconhecimento de voz inventada pela Evie. Também é
possível atribuir uma tecla ao atalho no próprio app Atalhos.

As ações exigem autenticação local do dispositivo e execução em primeiro plano.
A ação de tela passa pelo indicador e pela permissão de gravação já existentes.
A imagem permanece no fluxo normal de captura em memória. Preparar uma pergunta
não a envia ao modelo, não concede controle do Mac e não executa a pergunta.
Interações em andamento são recusadas para preservar o estado atual.

O próprio macOS exige os consentimentos de microfone, gravação de tela,
Acessibilidade e contas quando aplicáveis. App Intents não os substitui.

## O que a Evie já aproveita do sistema

- AppKit/SwiftUI e materiais nativos na interface.
- SpeechAnalyzer para transcrição, AVFoundation para áudio e vozes públicas.
- Vision para OCR e Foundation Models para a visão nas versões compatíveis.
- Automação pública AppleScript de Mail e Calendário nos adaptadores existentes.
- App Intents, agora, para disponibilizar as três ações acima.

`SystemLanguageModel.default.availability` é consultado pelo diagnóstico, sem
gerar texto, baixar modelos ou ativar Apple Intelligence. A disponibilidade do
modelo depende do hardware, da ativação de Apple Intelligence e do download
gerenciado pelo sistema. A integração não passa a usar o modelo do sistema como
substituto do PC ou do LensVLM. A busca web da Evie continua no adaptador web
próprio; os resultados não vêm da Siri.

## Permissões: estado observado no candidato (2026-10-17)

Disponibilizar App Intents ou habilitar as capacidades da Evie não concede
permissões do macOS. No checkpoint instalado, os cinco consentimentos principais
já estavam concedidos. A página pública **Privacidade e Segurança › Automação**
mostrou **Evie › Calendário habilitado**; Mail ainda não estava listado, portanto
seu pedido real continuava necessário. Abrir o Calendário em segundo plano não
leu eventos nem equivaleu a conceder uma permissão nova. Nenhuma mensagem ou
agenda foi consultada nessa inspeção dos Ajustes.

Também foi observado um pedido legítimo do Chaveiro exigindo a senha local do
proprietário para liberar a credencial do modelo. Essa interação pertence ao
macOS: a implementação não lê a senha, não a substitui por uma confirmação da
Evie e não declara autorização enquanto o sistema não a tiver concedido. O
relatório integrado registra a verificação posterior do bundle final; este
checkpoint não afirma que todos os consentimentos ou a publicação terminaram.

## Build e assinatura

O produto é um executável SwiftPM empacotado manualmente. Declarar tipos
`AppIntent` não basta para que o sistema descubra as ações.
`Scripts/evie-app build` chama `Scripts/evie-native-metadata` **antes** de assinar
o bundle. Esse script:

1. Compila as declarações independentes em `NativeAppleIntents.swift`, com o
   mesmo nome de módulo `EvieShell` e deployment target macOS 26.
2. Extrai valores constantes com a lista de protocolos distribuída pelo próprio
   toolchain selecionado, normalizada para o formato aceito pelo compilador.
3. Executa o `appintentsmetadataprocessor` do Xcode.
4. Confere os três identificadores e três App Shortcuts no recurso gerado
   `Contents/Resources/Metadata.appintents/extract.actionsdata`.

Falha de extração ou recurso incompleto interrompe o build. A assinatura cobre
os metadados. Nenhum entitlement privado, extensão, daemon, socket, LaunchAgent,
timer ou processo residente foi adicionado. O bridge guarda uma closure no ator
principal enquanto a Evie está aberta; a closure é removida ao encerrar.

## Verificação reproduzível

`--native-apple-check` é um diagnóstico isolado: usa texto sintético, chama os
três métodos reais `AppIntent.perform`, verifica o encaminhamento e os erros de
inicialização incompleta/interface ocupada, valida pergunta vazia e o limite de
8.000 caracteres Unicode, e confere os metadados do bundle. Não fotografa a
tela nem executa cliques; o destino da interface é substituído só nesse processo
de diagnóstico. `NativeAppleCheck.report()` oferece `success`, `checks` e `error`
em um resultado `Encodable` para validação automatizada da instalação.

Verificações executadas nesta implementação:

- `swiftc -target arm64-apple-macosx26.0 -warnings-as-errors` nas duas novas
  fontes e execução do diagnóstico em um bundle de teste com metadados reais:
  todos os checks passaram, incluindo 3 ações e 3 App Shortcuts.
- `Scripts/evie-native-metadata` executado de verdade com Xcode 27.1 (27A9275),
  SDK macOS 27.0 (`xcrun --show-sdk-version`), macOS 27.2 (26B5086k), Apple M5,
  24 GB: extração/validação
  concluída; uma execução levou 4,17 s (build, não custo em idle).
- `zsh -n Scripts/evie-app Scripts/evie-native-metadata` passou.
- O diagnóstico isolado informou Foundation Models disponível; medição avulsa
  com `/usr/bin/time -l`: 0,01 s, RSS máximo 14.876.672 bytes. Esses números
  são do processo de diagnóstico; não medem o consumo incremental da Evie.

A descoberta pelo sistema e o reconhecimento de voz da Siri são uma fronteira
adicional à compilação e ao diagnóstico. Para validar uma instalação, execute as
três ações pelo app Atalhos e confira o campo aberto, o rascunho sintético e a
captura com indicador. Só esse teste comprova a descoberta e invocação naquela
instalação; Siri pode estar desativada, indisponível no idioma ou depender da
indexação do macOS. O relatório integrado da release registra a evidência real.

Referências públicas: [AppIntent](https://developer.apple.com/documentation/appintents/appintent),
[configuração de execução](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents),
[App Shortcuts](https://developer.apple.com/videos/play/wwdc2024/10210/).
