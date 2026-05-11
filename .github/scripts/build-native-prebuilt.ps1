param(
  [ValidateSet("windows")]
  [string] $Platform = "windows",
  [Parameter(Mandatory = $true)]
  [string] $OutputDir
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "../..")
$buildRoot = if ($env:LIB_LLAMA_CPP_PREBUILD_BUILD_DIR) {
  $env:LIB_LLAMA_CPP_PREBUILD_BUILD_DIR
} else {
  Join-Path $repoRoot "build/prebuilt"
}

$buildDir = Join-Path $buildRoot "windows-x64"
$destination = Join-Path $OutputDir "windows/x64"
New-Item -ItemType Directory -Force -Path $destination | Out-Null

cmake `
  -S (Join-Path $repoRoot "packages/lib_llama_cpp_windows/src") `
  -B $buildDir `
  -A x64 `
  -DCMAKE_BUILD_TYPE=Release

cmake --build $buildDir --config Release --target lib_llama_cpp_windows --parallel 2

$dll = Get-ChildItem -Path $buildDir -Recurse -Filter "lib_llama_cpp_windows.dll" |
  Select-Object -First 1

if ($null -eq $dll) {
  Get-ChildItem -Path $buildDir -Recurse -File | Select-Object -ExpandProperty FullName
  throw "Could not find lib_llama_cpp_windows.dll under $buildDir"
}

Copy-Item -Path $dll.FullName -Destination (Join-Path $destination "lib_llama_cpp_windows.dll") -Force
