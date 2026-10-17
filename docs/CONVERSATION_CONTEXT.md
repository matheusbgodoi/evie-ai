# Contexto visível e compactação de conversa

`EvieConversationCompaction` prepara o histórico para o orçamento de entrada do
modelo que vai responder. O registro visível completo continua no armazenamento
existente. A compactação trabalha em cópias na memória e não salva resumos no
histórico, nas memórias pessoais, em logs ou em arquivos.

## Comportamento

Antes de enviar a pergunta, a Evie mede o prefixo preparado. Ao atingir cerca de
75% do orçamento, resume as mensagens antigas e prefere manter os últimos seis
turnos completos. Ao mudar para um modelo menor, inclui mais desses turnos no
resumo se necessário, até mesmo uma resposta recente grande demais para caber.
A mensagem de sistema e tudo que pertence à pergunta atual — texto, instruções
de habilidade, evidências e anexos — permanecem íntegros.

Se a pergunta atual por si só não couber, a operação retorna um erro legível
pedindo menos anexos ou um modelo com mais contexto. Não corta a pergunta nem
envia silenciosamente um prompt maior que o orçamento calculado.

O resumo guarda fatos, nomes, decisões, preferências, correções e pendências.
Ele é uma representação reduzida gerada por um modelo e pode omitir detalhes ou
conter erros. O histórico completo permanece disponível para conferência. Não
se promete equivalência semântica perfeita ou conhecimento integral de uma
conversa que excedeu o contexto do modelo.

## Segurança e limites

- A geração do resumo usa um pedido separado, sem ferramentas e com raciocínio
  desligado. As mensagens antigas chegam como dados em uma única mensagem de
  usuário; não são reapresentadas como instruções de sistema.
- No pedido final, o resumo também tem papel `user`, delimitado como dados sem
  autoridade. Ele não constitui aprovação para enviar, apagar, clicar ou salvar.
- Se alguma fonte antiga veio de imagem/tela, o resumo mantém
  `derivedFromPicture`; as proteções de ferramentas e aprovação automática
  continuam reconhecendo essa origem.
- O resumo tem até `min(6.000, orçamento/8, espaço disponível)` caracteres.
  Resposta vazia, truncada, excessiva, com ferramentas ou com encerramento
  inválido falha sem descartar o histórico original.
- Se a origem couber no modelo de destino, é feita uma única chamada. Caso
  contrário, trechos de até 100.000 caracteres, reduzidos pelo orçamento real do
  destino e pelas reservas do resumo, são processados em sequência. No cérebro
  local sob demanda, o teto é 24.000 caracteres por trecho para limitar o prefill.
  Nenhum trecho é enviado acima desse orçamento. Há no máximo 64 chamadas,
  cada uma com o prazo configurado para o perfil, limitado a 300 segundos,
  sem retries automáticos.
- Cancelar a tarefa cancela o pedido de resumo. `reset()` também cancela a
  tarefa ativa, invalida a geração e impede a publicação de resultados antigos.

## Cache e consumo

O cache é limitado a quatro entradas de resumo na memória do ator pertencente
ao view model. A chave inclui o destino, modelo, orçamento e fingerprint SHA-256
do prefixo coberto, incluindo proveniência visual. O cache não acessa credenciais
nem guarda pixels; o digest cobre texto da conversa e identificadores de imagens.

Na próxima pergunta, o resumo existente é reutilizado e os poucos turnos que
envelheceram desde a compactação ficam como texto original. Outro resumo só é
pedido quando esse prefixo preparado volta ao limiar. Isso evita resumir toda
a conversa novamente a cada pergunta. Mudar texto antigo ou o orçamento de
destino invalida o reaproveitamento correspondente. Limpar a conversa revoga
as operações e limpa o cache.

O consumo de tokens mostrado a partir de caracteres é uma estimativa, conforme
o orçamento de `EvieTurnPlan`. Quando o backend informa `AgentUsage`, o indicador
pode usar a contagem real de tokens do pedido concluído. O algoritmo garante o
limite de caracteres calculado; não possui o tokenizador privado de cada modelo
e não transforma estimativa em contagem exata.

## API de integração

```swift
let compaction = EvieConversationCompaction() // uma por view model
let prepared = try await compaction.prepare(
  history: history,
  tail: tail,
  budget: plan.characterBudget,
  client: brain.client,
  targetID: "identidade da conversa + perfil + modelo + contexto + endpoint",
  onProgress: { completed, total in /* atualizar UI no MainActor */ }
)
// Usar apenas no pedido, sem atribuir a conversation nem persistir messages.
let messages = prepared.messages
// Ao trocar de conversa/revogar uma operação:
await compaction.reset()
```

`Prepared` também informa `didCompact`, `estimatedInputTokens` e `usage` com os
caracteres original/preparado, orçamento, número de mensagens resumidas e
reaproveitamento do cache. A normalização de imagens por
`EvieTurnPlan.keepingNewestPictures` deve preceder a medição, para o orçamento
representar as imagens realmente enviadas.

## Verificação

`EvieConversationCompactionTests` cobre troca de orçamento 200.704 → 32.768,
pergunta atual íntegra, preservação de sistema, redução adaptativa de recentes,
pedidos de resumo dentro do orçamento, cache repetido e no turno seguinte,
chamada única quando cabe, origem visual, respostas inválidas e revogação de
uma chamada aguardada. Os testes usam um cliente controlado; eles verificam o
contrato e o cancelamento, não comprovam qualidade semântica de um modelo real.

Em 2026-10-17, `EvieContextCheck.run()` foi executado em um bundle de teste
assinado com a identidade da Evie, pelo transporte/credencial reais do PC
configurado. Foram usadas somente mensagens sintéticas. Resultado observado:
**46.247 → 16.374 caracteres**, dentro do orçamento de **32.768**; a pergunta
atual permaneceu idêntica, o fato antigo “projeto Aurora / cor azul” permaneceu
no resumo e a segunda preparação reutilizou o mesmo resumo. O relatório não
contém endpoint, credenciais, resumo nem histórico pessoal. Esse caso comprova
o percurso real e a retenção daquele fato de teste, sem prometer ausência de
perdas semânticas para todo histórico.

## Tempo de leitura de contextos grandes

Aceitar uma janela grande também exige esperar seu prefill. Os dados usados
para a política são o prefill sem cache de 150K tokens no PC, medido em cerca
de 250 segundos em 2026-10-16, e a primeira resposta após cerca de 128K tokens
no Mac, medida em aproximadamente 405 segundos em 2026-10-17. Não são tempos
prometidos para outras perguntas, nem comparações de qualidade.

`ModelDeadlinePolicy` preserva os prazos usuais de texto/imagem para entradas
até 16.384 tokens estimados. Acima disso, reserva **30 segundos + 6 ms por token**,
limitados pelo timeout configurado no perfil e pelo teto existente de 900 segundos.
Esse coeficiente é margem de agendamento sobre aquelas medições; não altera a
velocidade do modelo. O prazo final é o maior entre a reserva e o prazo já
existente, preservando também a tolerância de carregamento de um modelo frio.

O cliente estima a entrada pelos mesmos caracteres/imagens do planejamento,
divididos por dois, e compartilha o valor entre timeout de inatividade,
resposta de cabeçalhos e primeiro token. Para 131.072 tokens estimados e perfil
com timeout de 900 segundos, a reserva é de cerca de 816 segundos. Um perfil
configurado com 300 segundos limita a reserva a 300. O limite de duração total
do recurso permanece 900 segundos; cancelamento continua imediato. Os probes
de conectividade conservam seus prazos independentes e curtos.

A regressão do pedido real falhou antes da correção: uma entrada sintética de
128K tokens estimados ainda tinha somente 120 segundos de timeout de inatividade.
Os testes verificam os limites, compatibilidade das entradas pequenas e o cliente
streaming real contra um servidor simulado que retarda cabeçalhos ou primeiro
token. Esse teste de transporte não substitui a medição real do modelo.
O conjunto focado de prazos, corpo do pedido, streaming e persistência passou
58 testes em seis suítes, incluindo o cancelamento e os dois atrasos de transporte.

## Imagens pequenas no LensVLM

A validação de 2026-10-17 isolou um limite de resolução visual, não um sidecar
ignorado: o loader respeita o índice do checkpoint, incluindo os 333 tensores
visuais. Os pixels preparados e os IDs de tokens também corresponderam ao
frontend OptiQ de referência. A figura de teste `ZEBRA4817`, de 512 × 128, tinha
somente 64 tokens visuais e foi lida incorretamente. A mesma figura ampliada
para 1536 × 384, com 576 tokens visuais, foi lida corretamente no experimento.
Isso não transforma a ampliação em recuperação de informação inexistente.

`EvieLensImagePreparation` aplica essa preparação na cópia final enviada pelo
cliente, em todos os caminhos de inferência. A regra exige simultaneamente o
modelo exato `mlx-community/LensVLM-9B-OptiQ-4bit`, estilo `topLevel` e endpoint
loopback. Os outros modelos e hosts mantêm seus bytes originais. Não há
`resize_shape` global nem alteração no modelo, nos pesos ou no pacote upstream.

Imagens abaixo de 589.824 pixels são ampliadas proporcionalmente, com limite
de 4096 no lado maior, interpolação nearest e PNG sRGB. A dimensão vem do
cabeçalho ImageIO, não de metadados informados pelo chamador. O cliente recusa
imagens inválidas, entradas acima de 20 MiB ou dimensões acima de 16.777.216
pixels antes de decodificá-las. O limite total do pedido continua 60 MiB.
Imagens já grandes o suficiente permanecem byte a byte iguais. O limite lateral
pode impedir atingir a área mínima em figuras extremamente estreitas.

A cópia mantém os IDs de mensagem e imagem, origem e marca de conteúdo visual;
somente MIME, bytes e dimensões da imagem enviada refletem o novo PNG. O
histórico original não muda. Não há cache, arquivo temporário ou log com imagens
do usuário. A transformação usa sRGB explícito: DeviceRGB depende do perfil do
Mac e poderia mudar os valores RGB interpretados pelo servidor.

A regressão do corpo HTTP falhou antes da implementação (512 × 128 enviados)
e passou após a preparação (1536 × 384 enviados). O conjunto focado passou
61 testes em seis suítes, incluindo cores RGB puras, proveniência, integridade
da entrada, recusa de bytes inválidos, limites e estabilidade dos outros modelos.
Um probe com o helper de produção compilado gerou apenas a figura sintética:
1536 × 384, 20.493 bytes, ID preservado e origem intacta. Comparada à ampliação
PIL nearest usada no experimento, sua matriz de pixels foi **exatamente igual**,
com diferença máxima zero. A execução final do app assinado verifica o percurso
completo pelo cliente e pelo servidor reais.

## Tamanho de uma mensagem e da resposta

No chat, a entrada divide a janela com sistema, histórico, ferramentas, imagens
e reserva de saída: não há uma capacidade adicional só para a mensagem nova.
O painel distingue **contexto** de **saída máxima**: PC: 200.704/16.384 tokens e
Mac: 131.072/2.048 tokens. A reserva permite gerar até esse teto, sem obrigar uma
resposta longa. Tokens não equivalem a palavras nem a caracteres.

O limite de 8.000 caracteres da ação nativa “preparar uma pergunta” pertence a esse
AppIntent; não é o limite do chat nem a janela do modelo. Pesquisa por atalho
também tem sua própria resposta limitada. Para a pergunta atual que exceda o
orçamento do cérebro escolhido, o chat explica a capacidade e preserva o texto;
a compactação do histórico antigo não consegue tornar essa pergunta infinita.
