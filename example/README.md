# lib_llama_cpp_example

Example Flutter app for the app-facing `lib_llama_cpp` API.

The app expects callers to provide model files. It does not download or bundle a
GGUF model on behalf of the package.

## Real-Model Smoke

The mobile integration smoke is opt-in. Provide an app-accessible GGUF path with
`LIB_LLAMA_CPP_TEST_MODEL`:

```sh
flutter test \
  --dart-define=LIB_LLAMA_CPP_TEST_MODEL=/absolute/path/to/model.gguf \
  integration_test/mobile_smoke_test.dart -d <device-id>
```

CI runners should download and verify the model before invoking the test. The
package runtime should only receive the final model path.
