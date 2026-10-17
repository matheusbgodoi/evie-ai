# ADR 0023: App Intents públicos com metadados extraídos no bundle

Status: Accepted

Date: 2026-10-16

## Contexto

Integrar a Evie às tecnologias Apple requer uma fronteira pública estável. Siri
não fornece um backend privado que um aplicativo terceiro possa reutilizar como
se fosse seu modelo, navegador ou serviço de busca. App Intents expõe ações do
próprio aplicativo ao sistema, e funciona com Atalhos. O empacotamento SwiftPM
atual não executa automaticamente a fase Xcode de extração de metadados.

## Decisão

Oferecer três ações foreground e autenticadas localmente: abrir a conversa,
preparar uma pergunta para revisão e capturar a tela para a próxima pergunta.
As ações não enviam perguntas nem concedem autoridade ao agente. Um bridge no
ator principal aponta para os mesmos caminhos da interface existente; estado
ocupado resulta em erro, preservando a interação em andamento.

Extrair os valores constantes das declarações Swift do módulo `EvieShell` e
processá-los com `appintentsmetadataprocessor` do toolchain selecionado antes
da assinatura. O build exige os três intents e três App Shortcuts no recurso
gerado. O diagnóstico valida metadados e entry points sem conteúdo privado.

## Alternativas

- Copiar ou chamar componentes privados da Siri: dependência sem contrato
  público, indisponível como API e desnecessária para oferecer ações próprias.
- Apenas compilar structs AppIntent: não oferece metadados de descoberta no
  bundle manual e cria aparência de integração sem ação descoberta pelo sistema.
- Migrar todo o produto para um projeto Xcode: elimina a extração manual, mas
  amplia a mudança de build sem necessidade para estas três ações.
- Submeter diretamente o texto do Atalho ao agente: atribuiria autoridade a
  automações e conteúdo de outros aplicativos sem a revisão existente.

## Consequências

Nenhum serviço persistente adicional. Build requer Xcode com extrator App
Intents e falha explicitamente se ele não conseguir gerar o contrato. A política
de captura, permissões e aprovação continua nos adaptadores existentes. O macOS
controla indexação, descoberta e Siri; um diagnóstico de tipos/metadados não
substitui a invocação real no app Atalhos de uma instalação.
