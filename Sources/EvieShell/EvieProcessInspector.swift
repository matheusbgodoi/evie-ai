import Darwin
import Foundation

/// What the kernel says about a process, through libproc and `sysctl`: its
/// executable image, its argv, its children, which process listens on a port,
/// and on which addresses. Read-only, and limited to what the current user may inspect:
/// another user's process simply answers nothing.
enum EvieProcessInspector {
  /// The process's executable image (`proc_pidpath`). For a `#!` script that is
  /// the interpreter, with every symlink resolved.
  static func executablePath(of pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else {
      return nil
    }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
  }

  /// The process's argv (`KERN_PROCARGS2`): the argument count, the exec
  /// path, padding, then the arguments, each NUL-terminated.
  static func arguments(of pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    var arguments: [String] = []
    while arguments.count < count, index < size {
      let start = index
      while index < size, buffer[index] != 0 { index += 1 }
      arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
      index += 1
    }
    return arguments.count == count ? arguments : nil
  }

  /// Alive and not a zombie waiting to be reaped.
  static func isAlive(_ pid: pid_t) -> Bool {
    guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else {
      return false
    }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      return false
    }
    return info.pbi_status != UInt32(SZOMB)
  }

  /// When the process started, in microseconds since 1970, which with the
  /// pid names one process: a pid can be reused, the pair cannot.
  static func startTime(of pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      return nil
    }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
  }

  /// The pid itself and every process below it.
  static func selfAndDescendants(of pid: pid_t) -> Set<pid_t> {
    var found: Set<pid_t> = [pid]
    var pending = [pid]
    while let parent = pending.popLast() {
      var children = [pid_t](repeating: 0, count: 256)
      let bytes = proc_listchildpids(
        parent, &children, Int32(children.count * MemoryLayout<pid_t>.size))
      // Unlike the other libproc calls this one answers a count, not bytes.
      for child in children.prefix(Int(max(bytes, 0))) where child > 0 && !found.contains(child) {
        found.insert(child)
        pending.append(child)
      }
    }
    return found
  }

  /// The process listening on TCP `port`, if any. Every process this user can
  /// inspect is asked, which took 2.7 ms over 831 processes on 2026-10-16.
  static func listeningPID(onPort port: Int) -> pid_t? {
    allPIDs().first { listens($0, onPort: port) }
  }

  /// Whether the process holds a TCP socket listening on `port`, on any
  /// address.
  static func listens(_ pid: pid_t, onPort port: Int) -> Bool {
    listeningSockets(of: pid).contains { $0.port == port }
  }

  /// The local address and port of every TCP socket the process listens on,
  /// the address as `inet_ntop` writes it (`127.0.0.1`, `::1`, `0.0.0.0`,
  /// `::`).
  static func listeningSockets(of pid: pid_t) -> [(address: String, port: Int)] {
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else {
      return []
    }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
    let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, bytes)
    guard filled > 0 else {
      return []
    }
    var sockets: [(address: String, port: Int)] = []
    for descriptor in descriptors.prefix(Int(filled) / stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      var socket = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard
        proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
        socket.psi.soi_kind == SOCKINFO_TCP
      else {
        continue
      }
      let tcp = socket.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == TSI_S_LISTEN else {
        continue
      }
      let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
      sockets.append((localAddress(of: tcp.tcpsi_ini), Int(localPort)))
    }
    return sockets
  }

  /// `insi_laddr` as text. A v6 socket is read as v6 even when it also takes
  /// v4 (a dual-stack `::`); an address that cannot be read is "?", which no
  /// rule counts as loopback.
  private static func localAddress(of info: in_sockinfo) -> String {
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    var laddr = info.insi_laddr
    let written: UnsafePointer<CChar>?
    if info.insi_vflag & UInt8(INI_IPV6) != 0 {
      written = withUnsafePointer(to: &laddr.ina_6) {
        inet_ntop(AF_INET6, $0, &buffer, socklen_t(buffer.count))
      }
    } else if info.insi_vflag & UInt8(INI_IPV4) != 0 {
      written = withUnsafePointer(to: &laddr.ina_46.i46a_addr4) {
        inet_ntop(AF_INET, $0, &buffer, socklen_t(buffer.count))
      }
    } else {
      written = nil
    }
    guard written != nil else {
      return "?"
    }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private static func allPIDs() -> [pid_t] {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else {
      return []
    }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return pids.prefix(Int(max(count, 0))).filter { $0 > 0 }
  }
}
