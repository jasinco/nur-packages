# with import <nixpkgs> { };
{
  lib,
  stdenv,
  pkgs,
  buildGoModule,
  linkFarm,
  makeWrapper,
  overrideCC,
  cmake,
  gcc12,
  cudaPackages,
  linuxPackages,
  ollama,
  testers,
  nixosTests,
  ...
}:
let
  version = "0.2.3";
  src = builtins.fetchGit {
    url = "https://github.com/ollama/ollama.git";
    ref = "refs/tags/v${version}";
    submodules = true;
    shallow = true;
  };
  cudaToolkit = pkgs.buildEnv {
    name = "cuda-toolkit";
    ignoreCollisions = true;
    paths = [
      cudaPackages.cudatoolkit
      cudaPackages.cuda_cudart
      cudaPackages.cuda_cudart.static
    ];
    pathsToLink = [
      "/share"
      "/bin"
      "/include"
      "/lib"
    ];
  };
  runtimeLibs = [ linuxPackages.nvidia_x11 ];
  inherit (lib) licenses platforms maintainers;
  goBuild = buildGoModule.override { stdenv = overrideCC stdenv gcc12; };
in
goBuild rec {
  pname = "ollama";
  # to update version place lib.fakeHash in all the hash part then run it to get the hash
  nativeBuildInputs = [
    cmake
    makeWrapper
  ];
  buildInputs = [ cudaPackages.cuda_cudart ];
  inherit src version;

  vendorHash = "sha256-hSxcREAujhvzHVNwnRTfhi0MKI3s8HNavER2VLz6SYk=";
  preBuild = ''
    export CUDA_PATH=${cudaToolkit}
    export CUDA_LIB_DIR=${cudaToolkit}/lib
    export CUDACXX=${cudaToolkit}/bin/nvcc
    export OLLAMA_SKIP_PATCHING=true
    export CUDAToolkit_ROOT=${cudaToolkit}
    find ./llm/patches/ -type f -name "*.diff" -exec bash -c "patch -p1 -d ./llm/llama.cpp < \"{}\"" \;
    export EXTRA_CCFLAGS="-I/usr/include -I${cudaToolkit}/include -I/include"
    export CUDATOOLKITDIR=${cudaToolkit}
    export OLLAMA_CUSTOM_CPU_DEFS="-DGGML_CUDA=ON"
    export C_INCLUDE_PATH="/usr/include:${cudaToolkit}/include:/include"
    go generate ./...
  '';

  patches = [
    # disable uses of `git` in the `go generate` script
    # ollama's build script assumes the source is a git repo, but nix removes the git directory
    # this also disables necessary patches contained in `ollama/llm/patches/`
    # those patches are added to `llamacppPatches`, and reapplied here in the patch phase
    ./disable-git.patch
  ];
  postPatch = ''
    # replace inaccurate version number with actual release version
        substituteInPlace version/version.go --replace-fail 0.0.0 '${version}'
  '';
  postFixup = ''
    # the app doesn't appear functional at the moment, so hide it
    mv "$out/bin/app" "$out/bin/.ollama-app"
    # expose runtime libraries necessary to use the gpu
    mv "$out/bin/ollama" "$out/bin/.ollama-unwrapped"
    makeWrapper "$out/bin/.ollama-unwrapped" "$out/bin/ollama" --suffix LD_LIBRARY_PATH : '/run/opengl-driver/lib:${lib.makeLibraryPath runtimeLibs}'
  '';

  ldflags = [
    "-s"
    "-w"
    "-X=github.com/ollama/ollama/version.Version=${version}"
    "-X=github.com/ollama/ollama/server.mode=release"
    "-L ${cudaToolkit}/lib"
    "-L ${linuxPackages.nvidia_x11}/lib"
    "-L /lib"
  ];
  passthru.tests = {
    service = nixosTests.ollama;
    version = testers.testVersion {
      inherit version;
      package = ollama;
    };
  };
  meta = {
    description = "Get up and running with large language models locally";
    homepage = "https://github.com/ollama/ollama";
    changelog = "https://github.com/ollama/ollama/releases/tag/v${version}";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "ollama";
    maintainers = with maintainers; [ jasinco ];
  };
}
