<h1>
<p style="text-align: center;">
  <img width="243" height="199" alt="CuteMite" src="res/mite.png" />
  <br>mite
</p>
</h1>

> **Native Windows terminal rendering, GPU text drawing, and tabbed shell sessions built around libghostty.**

This repository provides a compact, production-grade terminal state for Windows. It combines a native Direct3D 11 renderer, DirectWrite text measurement, ConPTY shell hosting, tab lifecycle management, and libghostty's VT engine into a small executable with no Electron shell, no web runtime, and no hidden terminal stack.

## ✨ Features

- **⚡ Native Rendering**: Uses **Direct3D 11** and **DirectWrite** for GPU-backed terminal drawing and font measurement.
- **🧠 VT Processing**: Integrates **libghostty** for escape-sequence handling, screen state, selections, and scrollback behavior.
- **🪟 Windows Shell Hosting**: Runs shells through **ConPTY** with resize propagation and process lifecycle handling.
- **📑 Tab Infrastructure**: Supports tab creation, switching, closing, active-tab tracking, and per-tab terminal state.
- **📋 Clipboard Workflow**: Provides selection copy and paste integration with the Windows clipboard.
- **⚙️ Runtime Configuration**: Loads JSON configuration for fonts, colors, cursor behavior, shell command, opacity, and tab switcher location.

<img width="1075" height="767" alt="WindowsScreenshot" src="https://github.com/user-attachments/assets/7e80559c-a6e8-4f21-b4ed-6a5b6f2f6520" />

## 🧰 Build Environment

Before building mite, install Zig and ensure the Windows SDK/runtime components required by the Zig `win32` package are available.

- **Compiler**: Install a recent Zig toolchain.
- **Platform**: Build on Windows.
- **Graphics Stack**: Use a system with Direct3D 11 and DirectWrite support.
- **Terminal Backend**: Windows ConPTY support is required for shell hosting.

## 🚀 Deployment

Clone this repository, open PowerShell in the project root, and execute the following steps in order.

### 1. Verify the Build Gate

Compile mite and run the unit test suite:

```powershell
zig build check
```

### 2. Build a Release Binary

Build the optimized executable intended for daily use:

```powershell
zig build -Doptimize=ReleaseSafe
```

### 3. Locate the Executable

The release executable is written to:

```text
zig-out/bin/mite.exe
```

### 4. Run the Terminal

Launch mite directly from the build output:

```powershell
.\zig-out\bin\mite.exe
```
## 🖥️ Supported/Tested Systems

| Platform    | Graphics/Text Stack      | Shell Backend |
|-------------|--------------------------|---------------|
| **Windows** | Direct3D 11, DirectWrite | ConPTY        |

## Configuration Details

### 1. ⚙️ Application Configuration

Runtime defaults are loaded from the user configuration file. If no file exists, mite creates one from the embedded default JSON.

- **File**: `%USERPROFILE%\.config\mite\config.json`
- **Source**: [`src/config/config.zig`](src/config/config.zig)
- **Key Settings**: Fonts, colors, cursor fade, shell program, shell arguments, opacity, and tab switcher placement.

### 2. 🎨 Renderer

The renderer owns Direct3D device state, swap-chain setup, glyph texture management, and terminal cell drawing.

- **File**: [`src/renderer/terminal.zig`](src/renderer/terminal.zig)
- **D3D11 internals**: [`src/renderer/d3d11`](src/renderer/d3d11)
- **Text layout**: [`src/renderer/text/layout.zig`](src/renderer/text/layout.zig)

### 3. 🪟 Windows Platform Layer

Windows-specific behavior is isolated by responsibility:

- **Windowing**: [`src/platform/windows/window`](src/platform/windows/window)
- **Input and clipboard**: [`src/platform/windows/io`](src/platform/windows/io)
- **Process and command line handling**: [`src/platform/windows/process`](src/platform/windows/process)
- **Resources**: [`src/platform/windows/resources`](src/platform/windows/resources)

### 4. 🧩 App Runtime

The application layer coordinates startup, tab lifecycle, terminal resize policy, and the Win32 message procedure.

- **Runtime**: [`src/app/runtime.zig`](src/app/runtime.zig)
- **Window procedure**: [`src/app/window/procedure.zig`](src/app/window/procedure.zig)
- **Tabs**: [`src/app/tabs`](src/app/tabs)
- **Terminal behavior**: [`src/app/terminal`](src/app/terminal)

### 5. ✅ Test Suite

Unit tests are kept in dedicated test files and loaded through the test root.

- **Test root**: [`src/tests.zig`](src/tests.zig)
- **Config tests**: [`src/config/configtest.zig`](src/config/configtest.zig)
- **Tab switcher tests**: [`src/app/tabs/switchertest.zig`](src/app/tabs/switchertest.zig)
- **Command line tests**: [`src/platform/windows/process/commandlinetest.zig`](src/platform/windows/process/commandlinetest.zig)
- **Window grid tests**: [`src/platform/windows/window/gridtest.zig`](src/platform/windows/window/gridtest.zig)
