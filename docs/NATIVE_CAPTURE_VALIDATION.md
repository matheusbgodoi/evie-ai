# Validação do ciclo de confirmação de captura por URL

URLs externas não autorizam captura. O pedido `evie://capture` abre uma revisão;
a captura só pode partir da confirmação explícita, seguida das guardas atuais
do coordenador. O parser e o encaminhamento têm validações próprias. Este
ensaio cobre o controlador de revisão e a revogação de seus callbacks.

## Execução isolada

```zsh
Scripts/native-capture-validation --compile-only
Scripts/native-capture-validation --prove-regression
```

O primeiro comando compila o controlador real e a fixture em Swift 6 com avisos
como erros, sem iniciar interface ou SwiftPM. O segundo abre brevemente apenas
as janelas do processo descartável de teste; coordene seu uso com outras
validações do desktop. O modo padrão `--run` executa somente o caso atual.

O controlador recebe um `NotificationCenter` privado. O padrão de produção
continua sendo o centro de notificações do `NSWorkspace`; a mesma dependência
é usada para registrar e remover observadores. O teste não publica notificações
globais de sono ou sessão e não interage com Chaveiro, Atalhos ou outra Evie.

A confirmação chama um contador sintético, sem screenshot, envio, modelo,
concessão de controle, clipboard ou solicitação de permissão. O driver invoca
o próprio action handler usado pelo botão; isso comprova o ciclo e a revogação,
não a conexão visual do botão SwiftUI ou o funcionamento do app Atalhos.
A tentativa inicial de localizar o botão pela árvore AX interna não o expôs;
essa execução foi recusada como erro de driver, sem ser contada como regressão.

## Contrato e regressão

- Apresentar a revisão não invoca a confirmação.
- Confirmar fecha a revisão e invoca o callback uma única vez; nova chamada
  ao handler fechado não reutiliza a autorização.
- Cancelar, fechar a janela, interromper sem retomar escuta e encerrar o
  controlador eliminam a confirmação pendente.
- As notificações privadas de sono e de sessão inativa revogam sincronamente.
  O teste entrega a notificação e invoca imediatamente o action handler, sem
  `await` ou passagem pelo run loop entre essas operações. Não deve capturar
  nem solicitar a retomada da escuta.
- Encerrar o controlador remove seus observadores.

O controle vermelho compila uma cópia temporária do mesmo controlador,
alterando somente a revogação síncrona para o `Task { @MainActor ... }` anterior.
Usa a mesma fixture e as mesmas asserções. O script exige falha com o motivo
exato de confirmação obsoleta após sono; outra falha não serve como evidência.
Depois executa a fonte atual sem essa substituição.

Em 17/10/2026, no Mac de destino, o controle anterior falhou com
`sleep invalidation admitted a stale confirmation`; o controlador atual passou
todos os casos. Compilação com avisos como erros, strict lint, sintaxe do script
e `git diff --check` passaram. Os processos próprios terminaram e o foco
anterior foi restaurado. Nenhuma notificação real de sono/sessão foi enviada.

O resultado não substitui a revisão das guardas do coordenador, os testes de
URLs, a confirmação visual no app assinado ou a verificação de integração com
Atalhos. Esses limites impedem tratar um contador de teste como captura real.
