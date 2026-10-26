## 0.7.5

- Add asynchronous native ownership on a worker isolate while preserving the
  synchronous constructor. Close awaits native terminate/join/free.
- Preserve streaming payload/reasoning/tools/finish/usage, reject DONE-only streams
  and propagate socket disconnects to native cancellation.
- Expose long-context configuration and actual capability reports; return HTTP 400
  for invalid parameters/overflow and preserve structured native error codes.
- Fix delayed HTTP body reads and align default Linux/Windows library names.

## Unreleased

- Documented use through the app-facing `lib_llama_cpp` facade.

## 0.7.0

- Align package metadata with the workspace minor release.

## 0.1.0

- Initial local OpenAI-compatible HTTP server package.
- Added persistent `llcs_engine` wrapper, CLI entrypoint, HTTP routes, and a
  small Dart client.
