# lib_llama_cpp_example

Example Flutter app for the app-facing `lib_llama_cpp` API.

The app expects callers to provide model files. It does not download or bundle a
GGUF model on behalf of the package.

## Real-Model Smoke

The mobile integration smoke is opt-in. Provide an app-accessible GGUF path with
`LIB_LLAMA_CPP_TEST_MODEL`. When `LIB_LLAMA_CPP_TEST_MMPROJ` is also provided,
the test additionally exercises tool calls, image input, and audio input:

```sh
flutter test \
  --dart-define=LIB_LLAMA_CPP_TEST_MODEL=/absolute/path/to/model.gguf \
  --dart-define=LIB_LLAMA_CPP_TEST_MMPROJ=/absolute/path/to/mmproj.gguf \
  integration_test/mobile_smoke_test.dart -d <device-id>
```

CI runners should download and verify model files before invoking the test. The
package runtime should only receive final local file paths.
