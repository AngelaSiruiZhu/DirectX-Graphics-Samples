
## Build Script

A simplified build script `build_simple.ps1` has been added to `Samples/Desktop/D3D12MeshShaders/src/IntervalShadingTetrahedron/`.

### Usage

Run the script from PowerShell:

```powershell
.\Samples\Desktop\D3D12MeshShaders\src\IntervalShadingTetrahedron\build_simple.ps1
```

### Details

- **Tool:** Uses `MSBuild` (found via `vswhere`).
- **Configuration:** `Debug`, `x64`.
- **Target:** `IntervalShadingTetrahedron` project only.
- **Output:** The executable is built as `runnable.exe` in the `bin` subdirectory of the project folder.
