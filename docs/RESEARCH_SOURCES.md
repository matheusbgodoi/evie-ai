# Research sources

Last reviewed: 2026-08-04

Prefer pinned source revisions for implementation decisions and current official
documentation for capability discovery. Revalidate unstable claims before coding.

## TurboFieldfare and Gemma

- [TurboFieldfare repository](https://github.com/drumih/turbo-fieldfare)
- [Pinned local server documentation](https://github.com/drumih/turbo-fieldfare/blob/7a99f2a635e3adf7ed0720b882d2edb600f2f0da/docs/OPENAI_SERVER.md)
- [Pinned runtime KV cache manager](https://github.com/drumih/turbo-fieldfare/blob/7a99f2a635e3adf7ed0720b882d2edb600f2f0da/Sources/TurboFieldfare/Runtime/KVCache/KVCacheManager.swift)
- [Pinned architecture constants](https://github.com/drumih/turbo-fieldfare/blob/7a99f2a635e3adf7ed0720b882d2edb600f2f0da/Sources/TurboFieldfare/Infrastructure/ModelIO/ModelTypes.swift)
- [Pinned context-memory UI calculation](https://github.com/drumih/turbo-fieldfare/blob/7a99f2a635e3adf7ed0720b882d2edb600f2f0da/Sources/TurboFieldfareApp/Core/Configuration/AppContextLengthOption.swift)
- [Pinned KV experiment summary](https://github.com/drumih/turbo-fieldfare/blob/7a99f2a635e3adf7ed0720b882d2edb600f2f0da/docs/experiments/summaries/05-attention-and-kv-cache.md)
- [Pinned prompt-prefix cache](https://github.com/drumih/turbo-fieldfare/blob/7a99f2a635e3adf7ed0720b882d2edb600f2f0da/Sources/TurboFieldfareServer/Core/ServerPromptCache.swift)
- [Official Gemma 4 26B-A4B configuration](https://huggingface.co/google/gemma-4-26B-A4B/blob/main/config.json)
- [Pinned MLX checkpoint configuration](https://huggingface.co/mlx-community/gemma-4-26b-a4b-it-4bit/blob/0d77464eeb233a2da68ebf9d7dc4edaac7db956d/config.json)
- [Google Research TurboQuant overview](https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/)

## Hermes Agent

- [Repository](https://github.com/NousResearch/hermes-agent)
- [Documentation](https://hermes-agent.nousresearch.com/docs/)
- [64K local-model requirement](https://hermes-agent.nousresearch.com/docs/getting-started/quickstart)
- [Local/custom model providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
- [Tools and toolsets](https://hermes-agent.nousresearch.com/docs/user-guide/features/tools/)
- [Local API and session events](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server/)
- [Toolset reference](https://hermes-agent.nousresearch.com/docs/reference/toolsets-reference)
- [MCP integration](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp/)
- [Memory controls](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory/)
- [Tool Search progressive disclosure](https://hermes-agent.nousresearch.com/docs/user-guide/features/tool-search)
- [Context compression and caching](https://hermes-agent.nousresearch.com/docs/developer-guide/context-compression-and-caching/)
- [Profiles](https://hermes-agent.nousresearch.com/docs/user-guide/profiles/)
- [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security/)
- [Voice and custom STT/TTS providers](https://hermes-agent.nousresearch.com/docs/user-guide/features/tts/)
- [Google Workspace](https://hermes-agent.nousresearch.com/docs/user-guide/skills/google-workspace)
- [WhatsApp/Baileys](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/whatsapp)
- [Web search providers](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-search/)
- [QMD skill](https://hermes-agent.nousresearch.com/docs/user-guide/skills/optional/research/research-qmd)

## Voice

- [OmniVoice repository and CLI/Python examples](https://github.com/k2-fsa/OmniVoice)
- [OmniVoice model card](https://huggingface.co/k2-fsa/OmniVoice)
- [MLX Whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper)
- [Whisper large-v3-turbo model card](https://huggingface.co/openai/whisper-large-v3-turbo)
- [FluidAudio](https://github.com/FluidInference/FluidAudio)
- [FluidAudio speaker management](https://raw.githubusercontent.com/FluidInference/FluidAudio/main/Documentation/Diarization/SpeakerManager.md)
- [FluidAudio Core ML speaker model](https://huggingface.co/FluidInference/speaker-diarization-coreml)
- [Silero VAD](https://github.com/snakers4/silero-vad)
- [Apple Create ML sound classifier](https://developer.apple.com/documentation/CreateML/MLSoundClassifier)
- [Apple microphone permission](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)
- [openWakeWord](https://github.com/dscripka/openWakeWord)
- [LiveKit WakeWord](https://github.com/livekit/livekit-wakeword)
- [sherpa-onnx keyword spotting](https://k2-fsa.github.io/sherpa/onnx/kws/index.html)
- [Apple Sound Analysis](https://developer.apple.com/documentation/soundanalysis/)
- [Apple AVAudioEngine input](https://developer.apple.com/documentation/AVFAudio/AVAudioEngine/inputNode)
- [Apple voice-processing presentation](https://developer.apple.com/videos/play/wwdc2019/510/?time=404)

## CLUI CC and interface

- [Original CLUI CC](https://github.com/lcoutodemos/clui-cc)
- [CLUI CC architecture](https://github.com/lcoutodemos/clui-cc/blob/main/docs/ARCHITECTURE.md)
- [CLUI CC window implementation](https://github.com/lcoutodemos/clui-cc/blob/main/src/main/index.ts)
- [CLUI CC license](https://github.com/lcoutodemos/clui-cc/blob/main/LICENSE)
- [Later Clui fork](https://github.com/Youssef2430/clui)
- [Apple NSPanel](https://developer.apple.com/documentation/appkit/nspanel)
- [Apple NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)
- [Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Apple window collection behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)
- [Apple accessory activation policy](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory)
- [Apple Liquid Glass custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [KeyboardShortcuts Swift package](https://github.com/sindresorhus/KeyboardShortcuts)

## macOS lifecycle, permissions, and energy

- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple launchd guidance](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [Apple XPC](https://developer.apple.com/documentation/XPC)
- [Low Power Mode API](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled)
- [Dispatch memory pressure](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure)
- [App Sandbox limitations](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Energy best practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html)
- [Energy monitoring](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/MonitoringEnergyUsage.html)

## Automation

- [Running Node-RED locally](https://nodered.org/docs/getting-started/local)
- [Node-RED flow workspace](https://nodered.org/docs/user-guide/editor/workspace/flows)
- [Node-RED Admin API types](https://nodered.org/docs/api/admin/types)

## Retrieval and web search

- [QMD repository](https://github.com/tobi/qmd)
- [EmbeddingGemma 300M](https://huggingface.co/google/embeddinggemma-300m)
- [Qwen3 Embedding 0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)
- [node-llama-cpp](https://github.com/withcatai/node-llama-cpp)
- [sqlite-vec](https://github.com/asg017/sqlite-vec)
- [SQLite copyright/license](https://www.sqlite.org/copyright.html)
- [DDGS repository](https://github.com/deedy5/ddgs)
- [SearXNG documentation](https://docs.searxng.org/)

## Model candidates

- [Qwen 3.5 9B model card](https://huggingface.co/Qwen/Qwen3.5-9B)
- [Qwen 3 14B model card](https://huggingface.co/Qwen/Qwen3-14B)
- [Hermes 4 14B model card](https://huggingface.co/NousResearch/Hermes-4-14B)
- [Apple MLX](https://github.com/ml-explore/mlx)
