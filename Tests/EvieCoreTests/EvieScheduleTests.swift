import Foundation
import Testing

@testable import EvieCore

@Suite("Agendamentos")
struct EvieScheduleTests {
  private static let executable = URL(fileURLWithPath: "/Users/alguem/Applications/Evie.app/Contents/MacOS/evie-shell")
  private static let logs = URL(fileURLWithPath: "/Users/alguem/Library/Logs/Evie", isDirectory: true)

  private func plist(for schedule: EvieSchedule) -> EviePropertyList {
    EvieScheduleAgent.propertyList(
      for: schedule,
      executable: Self.executable,
      logDirectory: Self.logs
    )
  }

  /// The plist as `launchd` would read it back, rather than as we built it.
  /// Everything between the two — escaping, bridging, the plist DTD — is exactly
  /// what a test on the value alone would not cover.
  private func roundTripped(_ schedule: EvieSchedule) throws -> EviePropertyList {
    try EviePropertyList.parse(try plist(for: schedule).xmlData())
  }

  // MARK: - The label

  /// It is what `launchd` knows the job by for its whole life, so it may not
  /// depend on anything the user can change.
  @Test("o rótulo é estável e tem espaço de nomes")
  func labelIsNamespaced() {
    let schedule = EvieSchedule(
      id: "ab12cd34",
      name: "Resumo da manhã",
      prompt: "Resuma meus e-mails.",
      trigger: .daily(hour: 8, minute: 0)
    )
    #expect(schedule.label == "com.matheusbgodoi.evie.schedule.ab12cd34")

    var renamed = schedule
    renamed.name = "Outro nome"
    renamed.prompt = "Outra coisa"
    renamed.trigger = .daily(hour: 21, minute: 30)
    #expect(renamed.label == schedule.label)
  }

  @Test("o arquivo se chama como o rótulo")
  func fileNameMatchesLabel() {
    #expect(
      EvieScheduleAgent.fileName(forIdentifier: "ab12cd34")
        == "com.matheusbgodoi.evie.schedule.ab12cd34.plist"
    )
  }

  // MARK: - Cada tipo de gatilho

  @Test("todo dia vira um StartCalendarInterval só")
  func dailyIsOneInterval() throws {
    let job = try roundTripped(
      EvieSchedule(
        id: "0000aaaa",
        name: "Resumo da manhã",
        prompt: "Resuma meus e-mails não lidos e os eventos de hoje.",
        trigger: .daily(hour: 8, minute: 0)
      )
    )

    let interval = try #require(job["StartCalendarInterval"])
    #expect(interval["Hour"]?.integerValue == 8)
    #expect(interval["Minute"]?.integerValue == 0)
    // Sem Weekday: a chave ausente é o coringa, e é isso que faz "todo dia".
    #expect(interval["Weekday"] == nil)
    #expect(job["WatchPaths"] == nil)
    #expect(job["RunAtLoad"]?.booleanValue == false)

    let arguments = try #require(job["ProgramArguments"]?.arrayValue)
    #expect(arguments.count == 3)
    #expect(arguments[0].stringValue == Self.executable.path)
    #expect(arguments[1].stringValue == "--run-schedule")
    #expect(arguments[2].stringValue == "0000aaaa")
  }

  /// Vários dias são várias entradas com a mesma hora. Não existe chave "estes
  /// dias" — quem espera uma lista de Weekday dentro de um dicionário só
  /// descobre que não funciona na sexta seguinte.
  @Test("dias da semana viram uma entrada por dia")
  func weeklyIsOneIntervalPerDay() throws {
    let job = try roundTripped(
      EvieSchedule(
        id: "0000bbbb",
        name: "Varredura da pesquisa",
        prompt: "Liste o que mudou na pasta de pesquisa esta semana.",
        trigger: .weekly(weekdays: [5, 1], hour: 18, minute: 0)
      )
    )

    let intervals = try #require(job["StartCalendarInterval"]?.arrayValue)
    #expect(intervals.count == 2)
    // Ordenados, para que dois agendamentos iguais gerem o mesmo arquivo.
    #expect(intervals[0]["Weekday"]?.integerValue == 1)
    #expect(intervals[1]["Weekday"]?.integerValue == 5)
    #expect(intervals.allSatisfy { $0["Hour"]?.integerValue == 18 })
    #expect(intervals.allSatisfy { $0["Minute"]?.integerValue == 0 })
  }

  @Test("uma pasta vira WatchPaths, e não um relógio")
  func folderIsWatchPaths() throws {
    let job = try roundTripped(
      EvieSchedule(
        id: "0000cccc",
        name: "Chegou algo em Downloads",
        prompt: "Leia o arquivo mais recente e me diga o que é.",
        trigger: .folder(path: "/Users/alguem/Downloads")
      )
    )

    let watched = try #require(job["WatchPaths"]?.arrayValue)
    #expect(watched.count == 1)
    #expect(watched[0].stringValue == "/Users/alguem/Downloads")
    #expect(job["StartCalendarInterval"] == nil)
    // Sem isto, vinte arquivos baixados de uma vez viram vinte execuções.
    #expect(job["ThrottleInterval"]?.integerValue == 60)
  }

  // MARK: - Entrada hostil

  /// O nome é texto que o usuário escreveu e o plist é XML. Aspas, quebras de
  /// linha, `&` e `<` sobrevivem porque quem serializa é o Foundation, e não um
  /// template nosso.
  @Test("nome com aspas, quebras de linha e sinais de menor sobrevive")
  func hostileNameSurvivesTheXML() throws {
    let name = "Ele disse \"oi\" & <urgente>\nna segunda 'cedo'"
    let job = try roundTripped(
      EvieSchedule(
        id: "0000dddd",
        name: name,
        prompt: "Tanto faz.",
        trigger: .daily(hour: 7, minute: 5)
      )
    )
    #expect(job["EvieScheduleName"]?.stringValue == name)
    #expect(job["Label"]?.stringValue == "com.matheusbgodoi.evie.schedule.0000dddd")
  }

  @Test("pasta com & e < no nome sobrevive")
  func hostileFolderPathSurvivesTheXML() throws {
    let path = "/Users/alguem/Notas & Cia <2026>/entrada"
    let job = try roundTripped(
      EvieSchedule(
        id: "0000eeee",
        name: "Pasta esquisita",
        prompt: "Diga o que chegou.",
        trigger: .folder(path: path)
      )
    )
    #expect(job["WatchPaths"]?.arrayValue?.first?.stringValue == path)
  }

  /// O pedido não entra no plist. `~/Library/LaunchAgents` é legível por
  /// qualquer processo deste usuário, e "resuma os e-mails do Dr. Silva" não é
  /// coisa para ficar lá.
  @Test("o pedido não vai para o plist")
  func promptStaysOutOfThePlist() throws {
    let secret = "Resuma os e-mails do Dr. Silva sobre o exame."
    let data = try plist(
      for: EvieSchedule(
        id: "0000ffff",
        name: "Manhã",
        prompt: secret,
        trigger: .daily(hour: 8, minute: 0)
      )
    ).xmlData()
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("Dr. Silva"))
  }

  // MARK: - Validação

  @Test("um identificador que sai do lugar é recusado")
  func identifierIsChecked() {
    // Chegaria a `~/Library/LaunchAgents/<id>.plist` e a um argumento do
    // `launchctl` — os dois lugares onde uma barra é problema de outra pessoa.
    for bad in ["../../evil", "ab12cd3", "AB12CD34", "ab 12cd34", "zzzzzzzz", ""] {
      let schedule = EvieSchedule(
        id: bad,
        name: "Nome",
        prompt: "Pedido",
        trigger: .daily(hour: 8, minute: 0)
      )
      #expect(throws: EvieSchedule.ValidationFailure.identifierIsNotSafe) {
        try schedule.validate()
      }
    }
  }

  @Test("horas e minutos fora da faixa são recusados")
  func timeIsChecked() {
    #expect(throws: EvieScheduleTrigger.ValidationFailure.hourOutOfRange) {
      try EvieScheduleTrigger.daily(hour: 24, minute: 0).validate()
    }
    #expect(throws: EvieScheduleTrigger.ValidationFailure.minuteOutOfRange) {
      try EvieScheduleTrigger.daily(hour: 8, minute: 60).validate()
    }
    #expect(throws: EvieScheduleTrigger.ValidationFailure.noWeekdaysChosen) {
      try EvieScheduleTrigger.weekly(weekdays: [], hour: 8, minute: 0).validate()
    }
    #expect(throws: EvieScheduleTrigger.ValidationFailure.weekdayOutOfRange) {
      // 7 também é domingo para o launchd, mas aceitar as duas grafias faria
      // dois agendamentos diferentes na tela dispararem juntos.
      try EvieScheduleTrigger.weekly(weekdays: [7], hour: 8, minute: 0).validate()
    }
  }

  /// Um caminho relativo em `WatchPaths` não vigia nada, e isso é exatamente o
  /// que um agendamento que nunca dispara parece.
  @Test("caminho relativo é recusado")
  func relativePathIsRefused() {
    #expect(throws: EvieScheduleTrigger.ValidationFailure.pathIsNotAbsolute) {
      try EvieScheduleTrigger.folder(path: "Downloads").validate()
    }
  }

  @Test("nome e pedido vazios são recusados")
  func emptyFieldsAreRefused() {
    var schedule = EvieSchedule(
      id: "12345678",
      name: "   ",
      prompt: "Pedido",
      trigger: .daily(hour: 8, minute: 0)
    )
    #expect(throws: EvieSchedule.ValidationFailure.nameIsEmpty) { try schedule.validate() }

    schedule.name = "Nome"
    schedule.prompt = "\n  "
    #expect(throws: EvieSchedule.ValidationFailure.promptIsEmpty) { try schedule.validate() }
  }

  // MARK: - O que fica guardado

  /// O formato em disco é escrito à mão justamente para não mudar quando um
  /// `case` for renomeado. Se este teste quebrar, todo agendamento já salvo
  /// deixou de ser lido.
  @Test("o gatilho é gravado com uma chave estável")
  func triggerEncodingIsStable() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(EvieScheduleTrigger.weekly(weekdays: [3, 1], hour: 18, minute: 30))
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text == #"{"hour":18,"kind":"weekly","minute":30,"weekdays":[1,3]}"#)

    let decoded = try JSONDecoder().decode(EvieScheduleTrigger.self, from: data)
    #expect(decoded == .weekly(weekdays: [1, 3], hour: 18, minute: 30))
  }

  @Test("a descrição diz quando, em português")
  func summaryReads() {
    #expect(EvieScheduleTrigger.daily(hour: 8, minute: 0).summary == "Todo dia às 08:00")
    #expect(
      EvieScheduleTrigger.weekly(weekdays: [5], hour: 18, minute: 0).summary
        == "sex às 18:00"
    )
    #expect(
      EvieScheduleTrigger.weekly(weekdays: [0, 1, 2, 3, 4, 5, 6], hour: 7, minute: 0).summary
        == "Todo dia às 07:00"
    )
    #expect(
      EvieScheduleTrigger.folder(path: "/Users/alguem/Downloads").summary
        == "Quando algo mudar em Downloads"
    )
  }

  // MARK: - O plist como valor

  /// `true` e `1` chegam do Foundation como o mesmo `NSNumber`. Ler um `<true/>`
  /// de volta como inteiro faria um teste de ida e volta passar sobre um arquivo
  /// que diz outra coisa.
  @Test("booleano e inteiro não se confundem na volta")
  func booleansSurviveTheRoundTrip() throws {
    let value = EviePropertyList.dictionary([
      "sim": .boolean(true),
      "um": .integer(1),
    ])
    let parsed = try EviePropertyList.parse(try value.xmlData())
    #expect(parsed["sim"] == .boolean(true))
    #expect(parsed["um"] == .integer(1))
  }
}
