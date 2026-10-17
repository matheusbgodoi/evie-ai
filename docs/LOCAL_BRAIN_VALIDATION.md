# Local launcher boundary regression

Build the debug package with `Scripts/test`, then run
`Scripts/local-brain-validation`. This standalone regression compiles the
production `EvieLocalBrainLauncher`, `EvieProcessInspector`,
`EvieVoiceEngineLauncher`, and `EvieOmniVoiceClient` sources and links the existing
core debug object. It does not start another SwiftPM build. Both current Swift
Build aggregate objects and traditional SwiftPM object layouts are supported.

A temporary executable copy of `evals/fixtures/LocalBrainServer.py` receives the
absolute Python shebang from the installed MLX server. The fixture imports the
real `mlx.core` package and starts a lightweight loopback HTTP server. It loads
no model or tensor weights, makes no downloads, and writes no owner configuration.
The production bounded bootstrap applies the allocator limit before executing
this CLI. The fixture measures that real limit through `set_cache_limit`'s return
value and restores it immediately, without allocating a tensor.

The harness injects a temporary storage directory, temporary key file, ephemeral
port, and a zero memory admission floor suitable only for this synthetic server.
The production default admission policy is unchanged. PID lookup, executable
identity, command-line inspection, HTTP authentication, process launch, stop, and
restart all run through the production implementations against real OS processes.

The executable verifies:

- Initial model A uses KV 32,768, eight-bit KV, prefill step 256, one sequence,
  loopback binding, and the actual MLX allocator cache limit of 268,435,456 bytes.
- HTTP health rejects missing and wrong bearer tokens; the captured snapshot is
  available with the per-launch temporary key.
- A profile changed to model B and KV 65,536 is reported unready without
  interrupting the current server. `ensureRunning` then replaces its PID, starts
  with the new options and a new key, and rejects the previous key.
- Changing only the model to C also restarts the process, covering the branch
  where `LocalRuntime` itself is equal. Reusing identical profiles preserves PID.
- Stop removes the temporary PID/key state and frees the ephemeral port. It
  additionally requires `kill(pid, 0)` to fail with `ESRCH` immediately after
  `await launcher.stop()`, while the AppKit harness remains alive. A zombie-aware
  liveness helper alone is insufficient to prove the PID has been reaped.
- A different fixture executable occupying another ephemeral port is refused
  and stays alive and responsive. Test cleanup terminates only that explicitly
  owned fixture; no production listener is signalled.

The fixture deliberately does not claim to validate an MLX language model,
maximum supported context, generation quality, Metal memory at full context,
Siri, or the installed application bundle. Those require the separate real-model
and signed-bundle diagnostics. This regression validates the real launcher,
process, authentication, bounded-bootstrap, and configuration-change boundaries.

## AppKit process-reaping control — 2026-10-17

The installed real-model diagnostic observed its port free before strict PID
absence was visible. That observation was investigated without assuming that a
zombie still held model weights or that dropping a Foundation `Process` reference
was a proven cause. The dummy harness was changed to run through an actual
`NSApplication` run loop, keeping the host alive during the strict `ESRCH` check.

One investigatory execution repeated the complete A→B→C sequence three times
(nine owned dummy launches, plus three explicitly owned foreign-listener fixtures).
Every immediate post-stop strict check passed; total 7.37 s including standalone
compilation. The issue was **not reproduced** there, so no production launcher
change was made. The permanent harness runs one A→B→C sequence (three launches)
and retains the stronger AppKit/strict-PID assertion. A bounded observation wait
in the real-model diagnostic is validated separately against the installed bundle;
this dummy result is not substituted for that final check.
