# build_llama_cpp_cuda.sh

## Purpose

This script automates fetching the latest `llama.cpp` source code and compiling a **portable, CUDA-enabled build for Linux**. The resulting binaries are packaged into a versioned `.tar.gz` archive, ready to be distributed to other Linux machines that have compatible NVIDIA drivers and CUDA runtime libraries available.

## Behavior

### 1. Prerequisites Check
The script verifies that the following tools are installed and available in `PATH`:
- `git`
- `cmake` (version 3.20 or newer)
- `nvcc` (NVIDIA CUDA compiler)
- `nproc` (for parallel compilation)
- `strip` (optional; used to reduce binary size when available)

`cmake` and `nvcc` are also probed in common install locations that are not on
`PATH` by default and the script updates `PATH` when one is found there:
- `cmake`: `~/.local/bin/cmake` (a `pip install --user` cmake) and `/usr/local/bin/cmake`
- `nvcc`: `$CUDA_HOME/bin`, `$CUDA_PATH/bin`, `/usr/local/cuda/bin` (the Ubuntu
  CUDA `.deb` toolkit), and `/opt/cuda/bin`

If required tools are missing, the script aborts with a clear error message. If `strip` is missing, the build continues and prints a warning.

### 2. Source Management
- **First run:** Clones the latest `llama.cpp` source from `https://github.com/ggml-org/llama.cpp.git` using a shallow clone (`--depth 1`).
- **Subsequent runs:** If the `llama.cpp/` directory already exists and is a clean Git repository, the script updates it with `git pull --ff-only`.
- **Safety:** If the working tree is dirty (has uncommitted changes) or if `llama.cpp/` exists but is not a Git repository, the script aborts rather than risk overwriting data.

### 3. Build Configuration
CMake is configured for a **portable release build** with these flags:
- `-DGGML_CUDA=ON` - Enables the CUDA backend.
- `-DGGML_NATIVE=OFF` - Disables CPU-specific optimizations for the build host, improving CPU portability across Linux machines.
- `-DCMAKE_BUILD_TYPE=Release` - Produces optimized binaries.

### 4. Compilation
The project is compiled in parallel using all available CPU cores (`nproc`). This step may take several minutes depending on hardware.

### 5. Stripping
After a successful build, debug symbols are stripped from all executables in the `build/bin/` directory to reduce file size when `strip` is available.

### 6. Verification
The script checks that the following key binaries were produced:
- `llama-cli`
- `llama-server`
- `llama-quantize`

If any are missing, the script aborts.

### 7. Packaging
Binaries are copied into a staging directory and compressed into a timestamped tarball:
```text
dist/llama-cpp-cuda-linux-<timestamp>.tar.gz
```

The staging directory is cleaned up afterward.

### 8. Summary
Finally, the script prints:
- The full path to the generated tarball.
- The tarball's size.
- Quick usage instructions for the target machine.

## Important Notes

- **Target Machine Requirements:** The destination Linux system must have compatible NVIDIA drivers and runtime libraries available. The script does **not** bundle shared libraries such as `libcudart.so` or `libcublas.so`, so CUDA compatibility still depends on the build host CUDA toolkit and the target machine's driver/runtime combination.
- **Branch:** The script always builds from the latest `master` branch. It does not currently support checking out specific tags or branches.
- **Dirty Trees:** Local modifications inside the `llama.cpp/` directory will cause the script to abort. You must stash or discard changes before re-running.

## Usage

```bash
./build_llama_cpp_cuda.sh
```

The final tarball will be located in the `dist/` directory.

## Deploying a build into Llama GUI

### deploy-custom-slot.sh

`deploy-custom-slot.sh` installs one of the produced tarballs straight into the
app's **Custom** backend slot (`llama/custom/`), with no network download:

```bash
./deploy-custom-slot.sh                 # newest archive in dist/, slot "custom"
./deploy-custom-slot.sh path/to/pkg.tar.gz custom-02
```

Behavior, mirroring the app's own custom-backend flow:

- **Flat extraction:** binaries and shared libraries go into `llama/<slot>/bin/`
  and `*.gbnf`/`*.json` into `llama/<slot>/grammars/`.
- **Runtime probe first:** `llama-cli --version` must run against the staged
  files before the live slot is replaced, so a build that cannot start on this
  machine never clobbers a working slot.
- **Atomic swap:** the previous `bin/` is kept as `bin.old` until the new one is
  in place and probed, then removed.
- **Config:** `config.json` is updated exactly like "Activate Custom" in the app
  (`version=custom`, `backend=<slot>`, `tag=custom`). If an official backend was
  active, its name/tag/version are remembered as `official_install` so it can be
  restored later.
- **Restart:** if Llama GUI is already running, restart it after deployment so
  the Status page reads the new build.
