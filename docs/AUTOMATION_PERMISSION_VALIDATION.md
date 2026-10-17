# Automação de Mail e Calendário: pedido e validação

Atualizado em 2026-10-17.

O guia diferencia um aplicativo fechado de uma autorização negada. O retorno
`procNotFound` não permite concluir se existe consentimento; aparece como
**Aplicativo fechado**. Somente ao clicar **Permitir**, a Evie abre o destino
em segundo plano e consulta/pede autorização pela API pública de Automação.
Não consulta mensagens, eventos ou contas para pedir essa permissão.

A abertura usa `NSWorkspace.openApplication`, sem ativar o destino. A consulta
`AEDeterminePermissionToAutomateTarget` roda numa fila serial dedicada; renderizar
a interface apenas lê estado em cache. Enquanto o pedido está pendente o botão
fica indisponível, mas o ator principal continua livre. Atualizações antigas não
substituem o resultado de um pedido mais recente. Erros de abertura e códigos
inesperados ficam visíveis. Uma negativa oferece os Ajustes do Sistema; a Evie
não redefine nem modifica a base de permissões do macOS.

O pedido explícito em lote aguarda o estado de cada item antes de escolher a
ação. Abrir a Evie ou atualizar uma linha não abre Mail/Calendário por conta
própria. A autorização do Chaveiro para o modelo é uma fronteira separada.

## Regressão controlada

`Scripts/automation-permission-validation` compila, com Swift 6 e warnings como
erros, a classe de Automação e o ViewModel de permissões completos da produção,
junto do protocolo real. Injeta somente os limites de abertura, consulta de
consentimento e abertura dos Ajustes. Tipos usados exclusivamente pela fábrica
padrão são substitutos que falham se acionados; o teste usa itens explícitos.
Nenhum teste desse script abre apps, pede TCC, acessa Chaveiro ou lê dados pessoais.

Os nove casos verificam: destino fechado abre antes do pedido; negativa encaminha
aos Ajustes; falha de abertura não pede consentimento; código desconhecido é
exibido; cache e coalescência; descarte de consulta antiga; ator principal livre
e prevenção de pedidos duplicados; segunda abertura dos Ajustes limpa erro
anterior e notifica; pedido em lote aguarda a primeira consulta assíncrona.
Continuations e tarefas reais sincronizam esses casos, sem sleeps de adivinhação.

Dois controles temporários compilam e falham na asserção comportamental esperada:
um omite somente abrir o destino; o outro omite somente aguardar o estado no
ViewModel. Erros de compilação não contam como regressão reproduzida. O erro da
segunda abertura dos Ajustes também foi observado antes de sua correção.

Em 2026-10-17, os nove casos e os dois controles passaram no Mac de destino. O
script integra o job de Core no CI, usando os produtos isolados do próprio job.
O pacote completo passou em 1.556 casos (1.501 regulares e 55 de temporização);
essa rodada precede os dois últimos ajustes de Shell, cobertos pelo harness e
pela compilação release posterior. Não representa uma rodada nova após cada
edição de documentação.

## Fronteira instalada

Na versão anterior, a interface real reproduziu o erro: Calendário fechado
mostrava **Ainda não pedido**; abrir o aplicativo mudava para **Permitido**;
fechá-lo voltava ao estado incorreto. A autorização já existia. Não foi redefinida
para fabricar um diálogo de primeiro consentimento. No bundle corrigido instalado, a interface real mostrou **Aplicativo fechado**
e **Permitir**. Um único clique abriu o Calendário em segundo plano
(`running=true`, `active=false`) e mudou a linha para **Permitido**, sem botão.
O processo da Evie permaneceu o mesmo. A inspeção foi por Accessibility; nenhum
evento, conta ou campo de credencial foi lido. Foram restaurados somente os apps
e janelas abertos pelo teste. Esse fluxo já autorizado comprova a fronteira real
de abertura/consulta; negativas e primeiro consentimento ficam nos casos
controlados, sem alegação de um novo diálogo TCC.
