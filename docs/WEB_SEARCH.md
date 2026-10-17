# Pesquisa web

Revisado em 2026-10-17. A pesquisa está implementada: `EvieWebClient` consulta
o HTML público do DuckDuckGo e lê páginas públicas. Não usa DDGS, Docker,
SearXNG, contas, chaves de busca nem um worker residente. O plano DDGS de
2026-08-04 foi substituído pela implementação direta.

## Uso e dados enviados

Na configuração atual, pesquisa web vem habilitada por padrão, conforme pedido
do titular. Pode ser desligada no popover do cérebro ou nos Ajustes. O botão
explica que termos de busca vão ao DuckDuckGo e que páginas públicas são lidas.
Estar habilitada não cria uma busca contínua: a rede é usada quando a pergunta,
o comando `/web` ou uma ferramenta pede pesquisa. `/buscar` consulta as notas
locais, sem uma requisição web.

No PC, as ferramentas são `search_web` e `read_page`. O cérebro local que não
chama ferramentas recebe os trechos reunidos antes de gerar a resposta. A UI
indica as fontes usadas; uma resposta sem pesquisa não recebe crédito de web.
Busca web e integração Siri são recursos diferentes: os App Intents públicos
permitem abrir a Evie, preparar uma pergunta e capturar uma tela, sem acesso a
um motor privado de busca da Siri. Veja [integração Apple](NATIVE_APPLE.md).

## Limites implementados

- Até 6 resultados de busca; snippets de até 320 caracteres.
- Grounding lê até 3 páginas em paralelo e seleciona até 6 trechos pertinentes.
  Se as páginas não puderem ser lidas, pode usar os snippets identificados como
  tal. O leitor limita o texto extraído a 12.000 caracteres.
- Cada página tem um orçamento de 20 segundos, incluindo redirects, e até
  4 MiB de corpo. A transferência é interrompida no limite, antes de acumular
  uma resposta arbitrariamente grande.
- Sem retries automáticos, cache persistente, cookies, sessão autenticada,
  perfil de navegador ou execução de JavaScript.
- Conteúdo é texto, HTML/XHTML, JSON ou XML. Gzip/deflate são decodificados em
  stream pelo curl. O limite também é aplicado aos bytes já decodificados que
  chegam ao pipe, interrompendo expansões de conteúdo comprimido.

O parser depende do HTML do DuckDuckGo, que pode mudar ou apresentar desafios
anti-bot. Uma falha de rede é erro, não uma resposta inventada pelo modelo.
Não se oferece um SLA de disponibilidade para esse endpoint público. Páginas
cujo texto só aparece depois de executar JavaScript, como a documentação SPA
da Apple, podem não ter um corpo legível nesse leitor; snippets de busca
continuam disponíveis como evidência distinta de leitura da página.

## Fronteira de rede pública

`EviePublicWebFetcher` é separado do transporte do modelo para o PC do titular.
Ele aceita somente HTTP(S), nas portas padrão, sem usuário ou senha na URL.
Bloqueia nomes locais, endereços privados, loopback, link-local, multicast,
CGNAT, documentação, intervalos reservados e mecanismos IPv6 de transição.
Grafias IPv4 ambíguas, como octetos com zero inicial, também são recusadas.

Antes de cada conexão e redirect, todos os IPs devolvidos pelo DNS são
validados. Uma resposta com qualquer IP proibido é recusada. Os IPs aprovados
são fixados no transporte com `curl --resolve`; a conexão não faz uma segunda
resolução que permita trocar o destino para a LAN. O hostname original continua
usado em SNI e na verificação do certificado TLS. Há até três redirects, cada
um com a mesma validação; um POST 307/308 não é repassado a outra origem.

O transporte usa o `/usr/bin/curl` do macOS, sem shell. Configuração e URL vão
por stdin, evitando uma query em argumentos de processo. `--disable` evita
curlrc; ambiente, proxy, cookies, cache em disco e redirecionamento automático
não são herdados. Cada transferência termina seu processo e conserva somente
os bytes limitados em memória. Cancelar termina esse processo. A decisão e
alternativas estão no [ADR 0027](adr/0027-pinned-public-web-transport.md).

Conteúdo da web continua sendo dado não confiável. Páginas não autorizam novas
ações, mudanças de objetivo, leitura da rede local ou alteração das permissões.

## Verificação

`Scripts/test --filter EviePublicWeb` cobre URLs/IPs, DNS misto, rebinding em
redirect, limites, POST entre origens e MIME. A fronteira real é exercitada com
`curl` e um servidor HTTP que existe apenas durante o teste, ligado em loopback:
pin de um hostname `.invalid`, POST, ausência de cookies entre processos,
resposta chunked sem Content-Length, gzip válido, expansão comprimida excessiva,
cancelamento de HTTP/DNS e recusa da entrada pública
antes de qualquer conexão local. Esse servidor nunca consulta a internet.

`--web-check "Swift.org getting started"` usa uma consulta sintética na rede
real, lê um resultado e verifica recusas de endereços proibidos. Não inclua
perguntas pessoais em relatórios de diagnóstico destinados à publicação.

Resultados medidos ficam no [registro de validação](RESEARCH_VALIDATION.md).
