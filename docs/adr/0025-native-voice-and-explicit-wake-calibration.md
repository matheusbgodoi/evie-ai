# ADR 0025: Voz nativa e calibração explícita de cinco chamadas

Status: Accepted

Date: 2026-10-16

## Contexto

O proprietário prefere fala e reconhecimento nativos para evitar um worker de
voz pesado. Quer selecionar a voz e chamar “Evie”, com cinco gravações para
calibrar o reconhecimento. APIs públicas não oferecem o detector dedicado de
Siri nem prometem acesso às vozes dela. Nesta máquina, Sandra/Nando não podem
ser instanciadas em um bundle terceiro assinado; Luciana funciona.

## Decisão

Usar o pipeline existente SpeechAnalyzer/SpeechTranscriber e AVSpeechSynthesizer.
Oferecer seleção automática explícita e vozes pt-BR que o próprio app consegue
instanciar, com qualidade Apple padrão/aprimorada/premium e atualização por
notificação. Preservar clones e assets do usuário; o caminho nativo não inicia
o worker de clonagem.

Calibrar cinco chamadas curtas por gravação explícita e revisão da transcrição.
Persistir somente aliases plausíveis e data em arquivo local privado. Não criar
voiceprints, não identificar falante e não alegar treino de Siri. Aliases curtos
só correspondem exatamente a novos resultados finais, sem fuzzy ou decisões
baseadas em palpites voláteis. A coleta detém uma sessão exclusiva revogável
pelo cancelamento, parada de emergência ou encerramento.

Proteger a inicialização assíncrona do ouvinte com uma geração invalidada por
disarm, validada após cada await e em callbacks. Síntese nativa deve resolver
sua continuação uma única vez em conclusão, cancelamento ou prazo excedido;
tarefas antigas não podem prefazer nem finalizar uma fala nova.

## Alternativas

- Copiar detector ou vozes privados de Siri: sem contrato público e desnecessário
  para implementar reconhecimento e síntese nativos verificáveis.
- Tratar cinco gravações como clonagem ou biometria: entrega diferente do que o
  mecanismo implementa e cria retenção sensível desnecessária.
- Aceitar toda transcrição como alias: uma conversa capturada durante a coleta
  viraria palavra de ativação, ampliando falsos positivos.
- Excluir imediatamente modelos/clones anteriores: destruiria dados do usuário
  sem estabelecer equivalência de qualidade da voz nova.

## Consequências

Nenhum modelo adicional da Evie é carregado pelo caminho nativo. O ouvinte
continua usando microfone e serviços do macOS, sem promessa de custo zero.
Naturalidade depende das vozes públicas instaladas. A nova calibração exige
cinco entradas reais do usuário; testes sintéticos verificam o mecanismo, não
substituem essas entradas. Voz Pessoal não é ofertada no seletor de buffers
medidos, e não é criada por esta calibração.
