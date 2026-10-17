# ADR 0027: Transporte web público com DNS fixado e corpo limitado

- Data: 2026-10-16
- Estado: aceito

## Contexto

Pesquisa web existe no produto e passa a vir habilitada por padrão a pedido do
titular. O cliente anterior bloqueava alguns IPs escritos diretamente na URL,
mas não verificava DNS ou redirects, usava uma sessão compartilhada e aplicava
`prefix` somente depois de baixar o corpo inteiro. Um hostname público poderia
resolver para loopback ou rede privada. Uma validação DNS anterior à conexão,
sozinha, também deixa espaço para rebinding se o transporte resolver novamente.

## Decisão

Manter a API `EvieWebSearching` e mover sua transferência HTTP para uma fronteira
de rede pública em EvieCore. Cada hop valida a URL e todos os IPs do DNS, e
fixa os IPs permitidos no `/usr/bin/curl` usando `--resolve`. O hostname da URL
é preservado para SNI e validação TLS. O processo recebe uma configuração por
stdin, sem shell, proxy, ambiente herdado, curlrc, cookie jar ou cache em disco.

Limitar o corpo durante o stream; também limitar o buffer do pipe. Processar
até três redirects explicitamente, com DNS e política novos. Preservar
cancelamento e timeout. Não usar `--insecure`, autorização, JavaScript ou
descompressão sem limite. O curl decodifica gzip/deflate em stream; o pipe
aplica também o teto ao corpo decodificado. O leitor aceita formatos textuais.

Não reutilizar a política de transporte do modelo: o PC autorizado pertence a
uma rede privada, enquanto uma página arbitrária nunca recebe essa autoridade.

## Alternativas

- **URLSession efêmera com validação antes da chamada:** evita cookie/cache
  compartilhados, mas não fixa o resultado DNS aprovado na conexão.
- **Reescrever a URL para um IP em URLSession:** altera a identidade da conexão
  e exige tratamento próprio de SNI e certificado em hospedagens compartilhadas.
- **Cliente HTTP/TLS próprio em Network.framework:** pode fixar o IP e SNI,
  mas adiciona parser HTTP, chunking, TLS e cancelamento à superfície mantida.
- **libcurl por bindings novos:** evita criar processo, mas exige módulo C e
  configuração de distribuição adicionais. Não há medição que justifique isso
  para três páginas sob uma requisição explícita.

## Consequências e evidências

Não há serviço nem custo ocioso novo. Cada página cria um processo curto do
sistema; esse custo não é declarado zero. O limite continua aplicado no pipe
caso o servidor omita Content-Length. O curl 8.7.1 deste Mac também interrompe
corpos desconhecidos em `--max-filesize`; a expansão comprimida é limitada
independentemente pelo leitor do pipe. Cancelar ou expirar o DNS libera o
chamador; uma resposta posterior do resolver do sistema é descartada e não
inicia HTTP. Falhas de TLS ou do endpoint continuam falhas visíveis.

Testes usam material sintético e um servidor exclusivo em 127.0.0.1. Só o
transporte interno recebe o alvo de teste; a entrada pública continua recusando
loopback e os testes verificam que ela não alcança esse servidor. Não se
enfraquece a política para tornar uma integração verde.

Fontes primárias: [curl — --resolve](https://curl.se/docs/manpage.html#--resolve),
[--max-filesize](https://curl.se/docs/manpage.html#--max-filesize) e
[--disable](https://curl.se/docs/manpage.html#-q).
