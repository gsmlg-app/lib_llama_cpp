{ config, pkgs, ... }:

{
  nixpkgs.config = {
    allowUnfree = true;
    android_sdk.accept_license = true;
  };

  packages = with pkgs; [
    cmake
    dart
    flutter
    git
    llvmPackages.clang
    llvmPackages.libclang
    ninja
    pkg-config
  ];

  env.LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
  env.LLAMA_CPP_DIR = "${config.devenv.root}/third_party/llama.cpp";
}
