## 0.7.5

- Template all ordinary Chat/Responses messages once, including system/history.
- Own resident direct weights and serialize requests; rebuild each direct context
  safely for compact SWA. Add explicit asynchronous client/engine close.
- Cooperatively cancel native work, bound output buffering and decode UTF-8 across
  token boundaries. Report actual usage, output-limit finish and structured errors.
- Validate context/batch/thread/cache/FA settings and required desktop backends;
  preserve existing media/tool APIs and test projector overflow/recovery.
- Recommend worker-isolated `LlamaHttpServer.openAsync` and document native-window
  acceptance evidence separately from unsupported/unverified hardware.

## Unreleased

- Exported `lib_llama_cpp_server` from the app-facing facade and documented
  server mode as the recommended local-model integration path.
- Documented CPU-only pub.dev prebuilts with separate Metal, Vulkan, and CUDA
  GitHub release assets.
- Stream parsed plain-text deltas during tool-aware message generation while
  preserving structured tool-call parsing.
- Added Metal capability reporting for bundled Apple libraries and explicit
  unsupported-capability errors for bundled CPU-only libraries.
- Added CMake build options for Metal, CUDA, and Vulkan native backend builds.

## 0.4.0

- Added chat-template-aware `LlamaGenerateMessagesCommand` for multipart
  messages while keeping raw `LlamaGenerateCommand(prompt: ...)` unchanged.
- Added image/audio content parts, `mmprojPath` model configuration, runtime
  model capabilities, and unsupported-capability errors for media requests.
- Added OpenAI-style function tool definitions, tool choices, tool call
  responses, tool result message fields, and `requires_action` stream events.
- Document CPU-only native platform packages built by the GitHub release
  workflow.

## 0.1.0

- Initial release of the app-facing Flutter plugin facade.
- Added command and response types for model loading, generation, and disposal.
- Added inference isolate lifecycle orchestration and federated platform lookup.
