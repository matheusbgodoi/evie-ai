import Darwin
import Foundation

struct SecureProcessCommand: Sendable {
  let executableURL: URL
  let arguments: [String]
  let environment: [String: String]
  let workingDirectoryURL: URL
  let standardInput: Data
  let timeout: TimeInterval
  let terminationGracePeriod: TimeInterval
}

struct SecureProcessExit: Equatable, Sendable {
  let exitCode: Int32
}

enum SecureProcessRunnerError: Error, Equatable, Sendable {
  case invalidCommand
  case launchFailed(Int32)
  case inputWriteFailed
  case waitFailed(Int32)
  case timedOut
  case terminated(Int32)
}

/// Launches one bounded child process without a shell, inherited descriptors,
/// inherited environment, or captured output. The child receives a new process
/// group so cancellation also terminates descendants safely.
struct SecureProcessRunner: Sendable {
  func run(_ command: SecureProcessCommand) async throws -> SecureProcessExit {
    try Task.checkCancellation()
    guard
      command.executableURL.isFileURL,
      command.executableURL.path.hasPrefix("/"),
      command.workingDirectoryURL.isFileURL,
      command.workingDirectoryURL.path.hasPrefix("/"),
      command.timeout > 0,
      command.timeout.isFinite,
      command.terminationGracePeriod >= 0,
      command.terminationGracePeriod.isFinite,
      command.arguments.allSatisfy({ !$0.contains("\0") }),
      command.environment.allSatisfy({ key, value in
        !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
      })
    else {
      throw SecureProcessRunnerError.invalidCommand
    }

    let process = try spawn(command)
    process.scheduleTimeout(after: command.timeout)

    let exit = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: process.writeInputAndWait(command.standardInput))
        }
      }
    } onCancel: {
      process.requestStop(.cancelled)
    }

    try Task.checkCancellation()
    return exit
  }
}

extension SecureProcessRunner {
  private func spawn(_ command: SecureProcessCommand) throws -> RunningProcess {
    var inputDescriptors: [Int32] = [0, 0]
    let pipeResult = inputDescriptors.withUnsafeMutableBufferPointer { descriptors in
      Darwin.pipe(descriptors.baseAddress!)
    }
    guard pipeResult == 0 else {
      throw SecureProcessRunnerError.launchFailed(errno)
    }

    let childInput = inputDescriptors[0]
    let parentInput = inputDescriptors[1]
    guard
      fcntl(childInput, F_SETFD, FD_CLOEXEC) != -1,
      fcntl(parentInput, F_SETFD, FD_CLOEXEC) != -1,
      fcntl(parentInput, F_SETNOSIGPIPE, 1) != -1
    else {
      let code = errno
      Darwin.close(childInput)
      Darwin.close(parentInput)
      throw SecureProcessRunnerError.launchFailed(code)
    }

    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    let fileActionsResult = posix_spawn_file_actions_init(&fileActions)
    guard fileActionsResult == 0 else {
      Darwin.close(childInput)
      Darwin.close(parentInput)
      throw SecureProcessRunnerError.launchFailed(fileActionsResult)
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    let attributesResult = posix_spawnattr_init(&attributes)
    guard attributesResult == 0 else {
      Darwin.close(childInput)
      Darwin.close(parentInput)
      throw SecureProcessRunnerError.launchFailed(attributesResult)
    }
    defer { posix_spawnattr_destroy(&attributes) }

    let fileActionResults = [
      posix_spawn_file_actions_adddup2(&fileActions, childInput, STDIN_FILENO),
      posix_spawn_file_actions_addclose(&fileActions, parentInput),
      addDevNull(STDOUT_FILENO, to: &fileActions),
      addDevNull(STDERR_FILENO, to: &fileActions),
      addWorkingDirectory(command.workingDirectoryURL.path, to: &fileActions),
    ]
    if let failure = fileActionResults.first(where: { $0 != 0 }) {
      Darwin.close(childInput)
      Darwin.close(parentInput)
      throw SecureProcessRunnerError.launchFailed(failure)
    }

    var emptySignalMask = sigset_t()
    sigemptyset(&emptySignalMask)
    var defaultSignals = sigset_t()
    sigemptyset(&defaultSignals)
    for signal in [SIGINT, SIGQUIT, SIGPIPE, SIGTERM] {
      sigaddset(&defaultSignals, signal)
    }

    let spawnFlags = Int16(
      POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
        | POSIX_SPAWN_SETSIGMASK
    )
    let attributeResults = [
      posix_spawnattr_setflags(&attributes, spawnFlags),
      posix_spawnattr_setpgroup(&attributes, 0),
      posix_spawnattr_setsigmask(&attributes, &emptySignalMask),
      posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
    ]
    if let failure = attributeResults.first(where: { $0 != 0 }) {
      Darwin.close(childInput)
      Darwin.close(parentInput)
      throw SecureProcessRunnerError.launchFailed(failure)
    }

    var processIdentifier = pid_t()
    let argumentStrings = [command.executableURL.path] + command.arguments
    let environmentStrings = command.environment
      .map { "\($0.key)=\($0.value)" }
      .sorted()
    let result = withMutableCStringArray(argumentStrings) { argumentVector in
      withMutableCStringArray(environmentStrings) { environmentVector in
        posix_spawn(
          &processIdentifier,
          command.executableURL.path,
          &fileActions,
          &attributes,
          argumentVector,
          environmentVector
        )
      }
    }

    Darwin.close(childInput)
    guard result == 0 else {
      Darwin.close(parentInput)
      throw SecureProcessRunnerError.launchFailed(result)
    }

    return RunningProcess(
      processIdentifier: processIdentifier,
      inputDescriptor: parentInput,
      terminationGracePeriod: command.terminationGracePeriod
    )
  }

  private func addDevNull(
    _ descriptor: Int32,
    to fileActions: inout posix_spawn_file_actions_t?
  ) -> Int32 {
    "/dev/null".withCString { path in
      posix_spawn_file_actions_addopen(&fileActions, descriptor, path, O_WRONLY, 0)
    }
  }

  private func addWorkingDirectory(
    _ path: String,
    to fileActions: inout posix_spawn_file_actions_t?
  ) -> Int32 {
    path.withCString { directory in
      posix_spawn_file_actions_addchdir_np(&fileActions, directory)
    }
  }

  private func withMutableCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) rethrows -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer {
      for pointer in pointers where pointer != nil {
        free(pointer)
      }
    }
    return try pointers.withUnsafeMutableBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }
}

private final class RunningProcess: @unchecked Sendable {
  enum StopReason {
    case cancelled
    case inputWriteFailed
    case timedOut
  }

  private let processIdentifier: pid_t
  private let inputDescriptor: Int32
  private let terminationGracePeriod: TimeInterval
  private let lock = NSLock()
  private var finished = false
  private var stopReason: StopReason?

  init(
    processIdentifier: pid_t,
    inputDescriptor: Int32,
    terminationGracePeriod: TimeInterval
  ) {
    self.processIdentifier = processIdentifier
    self.inputDescriptor = inputDescriptor
    self.terminationGracePeriod = terminationGracePeriod
  }

  func scheduleTimeout(after timeout: TimeInterval) {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
      self?.requestStop(.timedOut)
    }
  }

  func requestStop(_ reason: StopReason) {
    lock.lock()
    guard !finished, stopReason == nil else {
      lock.unlock()
      return
    }
    stopReason = reason
    lock.unlock()

    signalProcessGroup(SIGTERM)
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + terminationGracePeriod
    ) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let shouldForce = !self.finished
      self.lock.unlock()
      if shouldForce {
        self.signalProcessGroup(SIGKILL)
      }
    }
  }

  func writeInputAndWait(_ input: Data) -> Result<SecureProcessExit, any Error> {
    let wroteInput = writeAll(input, to: inputDescriptor)
    Darwin.close(inputDescriptor)
    if !wroteInput {
      requestStop(.inputWriteFailed)
    }

    var status: Int32 = 0
    var waitResult: pid_t
    repeat {
      waitResult = waitpid(processIdentifier, &status, 0)
    } while waitResult == -1 && errno == EINTR

    lock.lock()
    finished = true
    let requestedStop = stopReason
    lock.unlock()

    if waitResult == processIdentifier {
      terminateAnyRemainingDescendants()
    }

    if let requestedStop {
      switch requestedStop {
      case .cancelled:
        return .failure(CancellationError())
      case .inputWriteFailed:
        return .failure(SecureProcessRunnerError.inputWriteFailed)
      case .timedOut:
        return .failure(SecureProcessRunnerError.timedOut)
      }
    }

    guard waitResult == processIdentifier else {
      return .failure(SecureProcessRunnerError.waitFailed(errno))
    }

    let terminatingSignal = status & 0x7F
    if terminatingSignal != 0 {
      return .failure(SecureProcessRunnerError.terminated(terminatingSignal))
    }

    return .success(SecureProcessExit(exitCode: (status >> 8) & 0xFF))
  }

  private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return true }
      var offset = 0
      while offset < rawBuffer.count {
        let count = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          rawBuffer.count - offset
        )
        if count > 0 {
          offset += count
        } else if count == -1 && errno == EINTR {
          continue
        } else {
          return false
        }
      }
      return true
    }
  }

  private func terminateAnyRemainingDescendants() {
    guard Darwin.kill(-processIdentifier, 0) == 0 else { return }
    signalProcessGroup(SIGTERM)
    if terminationGracePeriod > 0 {
      var interval = timespec(
        tv_sec: Int(terminationGracePeriod),
        tv_nsec: Int((terminationGracePeriod.truncatingRemainder(dividingBy: 1)) * 1_000_000_000)
      )
      var remaining = timespec()
      while nanosleep(&interval, &remaining) == -1 && errno == EINTR {
        interval = remaining
      }
    }
    signalProcessGroup(SIGKILL)
  }

  private func signalProcessGroup(_ signal: Int32) {
    _ = Darwin.kill(-processIdentifier, signal)
  }
}
