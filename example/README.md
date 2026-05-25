# lib_llama_cpp_example

Example Flutter app and E2E harness for the app-facing `lib_llama_cpp` API.

The app expects callers to provide model files. It does not download or bundle a
GGUF model on behalf of the package.

## Real-Model E2E Harness

The integration harness is opt-in. Provide an app-accessible GGUF path with
`LIB_LLAMA_CPP_TEST_MODEL`. When `LIB_LLAMA_CPP_TEST_MMPROJ` is also provided,
the test additionally exercises image input and audio input:

```sh
flutter test \
  --dart-define=LIB_LLAMA_CPP_TEST_MODEL=/absolute/path/to/model.gguf \
  --dart-define=LIB_LLAMA_CPP_TEST_MMPROJ=/absolute/path/to/mmproj.gguf \
  integration_test/e2e_harness_test.dart -d <device-id>
```

For sandboxed platforms, copy the verified model into `assets/e2e/` before the
test run and pass `LIB_LLAMA_CPP_TEST_MODEL_ASSET=assets/e2e/model.gguf`.

CI runners should download and verify model files before invoking the test. The
package runtime should only receive final local file paths.
