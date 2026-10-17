import CoreGraphics
import Foundation

public enum ComputerToolName: String, CaseIterable, Sendable {
  case lookScreen = "look_screen"
  case computer
  case clipboardWrite = "clipboard_write"
  case clipboardRead = "clipboard_read"
  case openApp = "open_app"
  case finish
}

/// The tools of a computer-use session.
///
/// They change the world, so they are kept apart from `EvieFileToolbox`, whose
/// tools only observe, and they are declared only to a loop that holds an
/// active `EvieAgentModeGrant`: `EvieAgentModeBroker.toolDefinitions(for:
/// convention:)` is the one way out of this module, and it gives nothing
/// without a live grant. Prompt injection cannot call a tool that was not
/// declared, and outside a session these never are.
///
/// The action vocabulary is Qwen's computer-use one, which the PC's model was
/// trained on, flattened to the string and integer arguments `EvieToolDefinition`
/// allows.
enum ComputerToolDefinitions {
  static func definitions(convention: CoordinateConvention) -> [EvieToolDefinition] {
    let space =
      switch convention {
      case .normalized1000:
        "de 0 a 1000 sobre a imagem da última observação (0,0 é o canto superior esquerdo)"
      case .pixels:
        "em pixels da imagem da última observação (0,0 é o canto superior esquerdo)"
      }
    return [
      EvieToolDefinition(
        name: ComputerToolName.lookScreen.rawValue,
        summary: """
          Olha a tela de novo: uma imagem sem as janelas da Evie e a lista dos \
          elementos do app da frente, com um observation_id novo. Chame antes da \
          primeira ação e sempre que a tela puder ter mudado.
          """,
        parameters: [
          EvieToolParameter(
            name: "target",
            type: .string,
            summary:
              "screen (a tela sob o ponteiro, o padrão) ou front_window (só a janela da frente)."
          )
        ]
      ),
      EvieToolDefinition(
        name: ComputerToolName.computer.rawValue,
        summary: """
          Uma ação no Mac, sobre a última observação. Prefira element a x/y. \
          Ações: left_click, right_click, middle_click, double_click, triple_click, \
          mouse_move, left_click_drag, type, key, scroll, wait, paste. Algumas \
          ações pedem a confirmação do Matheus antes; outras são recusadas, e a \
          recusa diz por quê.
          """,
        parameters: [
          EvieToolParameter(
            name: "action",
            type: .string,
            summary: "Qual ação fazer, da lista acima.",
            isRequired: true
          ),
          EvieToolParameter(
            name: "element",
            type: .integer,
            summary: "O número [n] de um elemento da última observação."
          ),
          EvieToolParameter(name: "x", type: .integer, summary: "Coordenada horizontal, \(space)."),
          EvieToolParameter(name: "y", type: .integer, summary: "Coordenada vertical, \(space)."),
          EvieToolParameter(
            name: "to_x",
            type: .integer,
            summary: "Para left_click_drag: x de onde soltar."
          ),
          EvieToolParameter(
            name: "to_y",
            type: .integer,
            summary: "Para left_click_drag: y de onde soltar."
          ),
          EvieToolParameter(name: "text", type: .string, summary: "Para type: o texto a digitar."),
          EvieToolParameter(
            name: "keys",
            type: .string,
            summary: "Para key: a tecla ou o atalho, como return, escape, tab ou cmd+shift+t."
          ),
          EvieToolParameter(
            name: "direction",
            type: .string,
            summary: "Para scroll: up, down, left ou right."
          ),
          EvieToolParameter(
            name: "amount",
            type: .integer,
            summary: "Para scroll: linhas, de 1 a 15 (padrão 3). Para wait: segundos, de 1 a 5."
          ),
          EvieToolParameter(
            name: "observation_id",
            type: .string,
            summary: "O observation_id da última observação.",
            isRequired: true
          ),
        ]
      ),
      EvieToolDefinition(
        name: ComputerToolName.clipboardWrite.rawValue,
        summary: "Copia um texto para a área de transferência, para colar depois com paste.",
        parameters: [
          EvieToolParameter(
            name: "text",
            type: .string,
            summary: "O texto a copiar.",
            isRequired: true
          )
        ]
      ),
      EvieToolDefinition(
        name: ComputerToolName.clipboardRead.rawValue,
        summary: "Lê o que está copiado. O Matheus confirma antes.",
        parameters: []
      ),
      EvieToolDefinition(
        name: ComputerToolName.openApp.rawValue,
        summary: """
          Abre um app pelo nome e, se quiser, um link https nele. Abrir um app que \
          o Matheus não pediu, ou um link, ele confirma antes.
          """,
        parameters: [
          EvieToolParameter(
            name: "name",
            type: .string,
            summary: "O nome do app, como aparece no Mac.",
            isRequired: true
          ),
          EvieToolParameter(name: "url", type: .string, summary: "Um link https:// para abrir."),
        ]
      ),
      EvieToolDefinition(
        name: ComputerToolName.finish.rawValue,
        summary: """
          Termina a sessão: success quando o pedido foi feito, failure quando não \
          deu, need_user quando falta algo que só o Matheus pode fazer.
          """,
        parameters: [
          EvieToolParameter(
            name: "status",
            type: .string,
            summary: "success, failure ou need_user.",
            isRequired: true
          ),
          EvieToolParameter(
            name: "summary",
            type: .string,
            summary: "O que foi feito, em uma ou duas frases.",
            isRequired: true
          ),
        ]
      ),
    ]
  }
}

public enum ComputerFinishStatus: String, Sendable, Equatable {
  case success
  case failure
  case needUser = "need_user"
}

/// A computer-use tool call, read into Evie's own types.
public enum ComputerToolRequest: Sendable, Equatable {
  public enum LookTarget: String, Sendable, Equatable {
    case screen
    case frontWindow = "front_window"
  }

  case look(LookTarget)
  case act(ComputerAction)
  case finish(ComputerFinishStatus, summary: String)

  /// Reads `call` against the latest observation.
  ///
  /// Every `computer` call must name that observation: an element number or a
  /// point read from an older screen is refused here, with a reason the model
  /// can act on, before the policy sees it. A pixel answer (`.pixels`) is
  /// moved onto the 0–1000 grid of the image it was about; what lies beyond
  /// the image stays beyond the grid, for the policy to refuse.
  public static func parse(
    _ call: EvieToolCall,
    latest: ComputerObservation?,
    convention: CoordinateConvention
  ) throws -> ComputerToolRequest {
    guard let name = ComputerToolName(rawValue: call.name) else {
      throw ComputerToolParseError.notAComputerTool
    }
    let arguments: Arguments
    do {
      arguments = Arguments(values: try call.arguments())
    } catch {
      throw ComputerToolParseError.unreadableArguments
    }

    switch name {
    case .lookScreen:
      guard let text = arguments.text("target") else {
        return .look(.screen)
      }
      guard let target = LookTarget(rawValue: text) else {
        throw ComputerToolParseError.invalidArgument("target")
      }
      return .look(target)
    case .clipboardRead:
      return .act(.readClipboard)
    case .clipboardWrite:
      return .act(.writeClipboard(try arguments.requiredText("text")))
    case .openApp:
      let appName = try arguments.requiredText("name")
      guard let link = arguments.text("url") else {
        return .act(.openApp(name: appName, url: nil))
      }
      guard let url = URL(string: link) else {
        throw ComputerToolParseError.invalidArgument("url")
      }
      return .act(.openApp(name: appName, url: url))
    case .finish:
      guard let status = ComputerFinishStatus(rawValue: try arguments.requiredText("status")) else {
        throw ComputerToolParseError.invalidArgument("status")
      }
      return .finish(status, summary: try arguments.requiredText("summary"))
    case .computer:
      let observationID = try arguments.requiredText("observation_id")
      guard let latest else {
        throw ComputerToolParseError.noObservation
      }
      guard observationID == latest.id else {
        throw ComputerToolParseError.staleObservation
      }
      let reader = TargetReader(
        arguments: arguments,
        observation: latest,
        convention: convention
      )
      return .act(try computerAction(arguments, reader: reader))
    }
  }

  private static func computerAction(
    _ arguments: Arguments,
    reader: TargetReader
  ) throws -> ComputerAction {
    switch try arguments.requiredText("action") {
    case "left_click", "click":
      return .click(try reader.target(), button: .left, count: 1)
    case "right_click":
      return .click(try reader.target(), button: .right, count: 1)
    case "middle_click":
      return .click(try reader.target(), button: .middle, count: 1)
    case "double_click":
      return .click(try reader.target(), button: .left, count: 2)
    case "triple_click":
      return .click(try reader.target(), button: .left, count: 3)
    case "mouse_move":
      return .moveMouse(try reader.target())
    case "left_click_drag", "drag":
      return .drag(from: try reader.target(), to: try reader.point(x: "to_x", y: "to_y"))
    case "type":
      return .typeText(try arguments.requiredText("text"))
    case "key":
      guard let chord = KeyChord(parsing: try arguments.requiredText("keys")) else {
        throw ComputerToolParseError.invalidArgument("keys")
      }
      return .pressKeys(chord)
    case "scroll":
      let lines = try arguments.integer("amount", default: 3, in: 1...15)
      let (dx, dy): (Int, Int) =
        switch try arguments.requiredText("direction") {
        case "up": (0, -lines)
        case "down": (0, lines)
        case "left": (-lines, 0)
        case "right": (lines, 0)
        default: throw ComputerToolParseError.invalidArgument("direction")
        }
      return .scroll(try reader.target(), dx: dx, dy: dy)
    case "wait":
      return .wait(seconds: try arguments.integer("amount", default: 1, in: 1...5))
    case "paste":
      return .paste
    default:
      throw ComputerToolParseError.unknownAction
    }
  }

  /// The flat strings `EvieToolCall.arguments()` produces, read as text and
  /// whole numbers. A number may arrive as `500`, `"500"` or `8.6`; anything
  /// fractional is rounded to the nearest grid step.
  private struct Arguments {
    let values: [String: String]

    func text(_ key: String) -> String? {
      guard let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
      else {
        return nil
      }
      return value
    }

    func requiredText(_ key: String) throws -> String {
      guard let value = values[key], !value.isEmpty else {
        throw ComputerToolParseError.missingArgument(key)
      }
      return value
    }

    func number(_ key: String) throws -> Double? {
      guard let text = text(key) else {
        return nil
      }
      guard let value = Double(text), value.isFinite, abs(value) < 1_000_000 else {
        throw ComputerToolParseError.invalidArgument(key)
      }
      return value
    }

    func integer(_ key: String, default fallback: Int, in range: ClosedRange<Int>) throws -> Int {
      guard let value = try number(key) else {
        return fallback
      }
      let rounded = Int(value.rounded())
      guard range.contains(rounded) else {
        throw ComputerToolParseError.invalidArgument(key)
      }
      return rounded
    }
  }

  private struct TargetReader {
    let arguments: Arguments
    let observation: ComputerObservation
    let convention: CoordinateConvention

    /// `element` when given, else `x` and `y`.
    func target() throws -> ComputerAction.Target {
      if let index = try arguments.number("element") {
        return .element(observationID: observation.id, index: Int(index.rounded()))
      }
      return try point(x: "x", y: "y")
    }

    func point(x xKey: String, y yKey: String) throws -> ComputerAction.Target {
      guard let x = try arguments.number(xKey) else {
        throw ComputerToolParseError.missingArgument(xKey)
      }
      guard let y = try arguments.number(yKey) else {
        throw ComputerToolParseError.missingArgument(yKey)
      }
      switch convention {
      case .normalized1000:
        return .normalized(x: Int(x.rounded()), y: Int(y.rounded()), observationID: observation.id)
      case .pixels:
        let image = observation.frame.imageSize
        guard image.width > 0, image.height > 0 else {
          throw ComputerToolParseError.noObservation
        }
        let extent = Double(ScreenGeometry.normalizedGridExtent)
        return .normalized(
          x: Int((x * extent / Double(image.width)).rounded()),
          y: Int((y * extent / Double(image.height)).rounded()),
          observationID: observation.id
        )
      }
    }
  }
}

/// Why a computer-use call could not be read. The message goes back to the
/// model as the tool's result, so it says what to do instead, and it never
/// repeats what the model sent.
public enum ComputerToolParseError: Error, Equatable, Sendable {
  case notAComputerTool
  case unreadableArguments
  case missingArgument(String)
  case invalidArgument(String)
  case unknownAction
  case noObservation
  case staleObservation
}

extension ComputerToolParseError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notAComputerTool:
      "Essa ferramenta não existe nesta sessão."
    case .unreadableArguments:
      "Os argumentos não puderam ser lidos; mande um objeto JSON simples."
    case .missingArgument(let name):
      "Falta o argumento \(name)."
    case .invalidArgument(let name):
      "O argumento \(name) não é válido."
    case .unknownAction:
      "Essa ação não existe. Use uma da lista da ferramenta computer."
    case .noObservation:
      "Olhe a tela primeiro com look_screen."
    case .staleObservation:
      "Esse observation_id não é o da última observação; a tela pode ter mudado. "
        + "Use o da última, ou olhe de novo com look_screen."
    }
  }
}
