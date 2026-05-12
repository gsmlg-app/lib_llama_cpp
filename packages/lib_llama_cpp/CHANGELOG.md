## Unreleased

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
