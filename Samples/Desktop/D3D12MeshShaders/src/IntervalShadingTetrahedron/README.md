# Interval Shading Tetrahedron (DX12 Mesh Shaders)

This sample demonstrates **Interval Shading**, a technique for order-independent volume rendering using **DirectX 12 Mesh Shaders**. It generates per-pixel front and back depth intervals from a tetrahedral mesh and accumulates optical depth to simulate volumetric effects like fog and crystal transmittance.

Based on the paper: *Interval Shading: using Mesh Shaders to generate shading intervals for volume rendering* (Tricard 2024).

## Controls

| Key | Action |
| :--- | :--- |
| **1** | Debug View: **Front Depth** (White = Near, Black = Far) |
| **2** | Debug View: **Back Depth** |
| **3** | Debug View: **Interval Length** (Heatmap: Red/Yellow = Thick, Blue = Thin) |
| **4** | Debug View: **Optical Depth (Tau)** (Heatmap) |
| **5** | Render Mode: **Transmittance** (Beer-Lambert law, Grayscale) |
| **6** | Render Mode: **Fog/Crystal** (Volumetric compositing) |
| **R** | **Randomize** Tetrahedron Draw Order (Verifies order-independence) |
| **Arrow Left/Right** | Rotate Camera (Yaw) |
| **Arrow Up/Down** | Rotate Camera (Pitch) |
| **W / S** | Zoom In / Out |

## Implementation Details

### Pipeline
1.  **Mesh Shader (`IntervalShadingMS.hlsl`):**
    *   Loads a Tetrahedral Mesh (`.vtk`).
    *   Performs near-plane clipping (splitting tets into prisms/tets).
    *   Generates "Proxy Triangles" representing the front/back faces of the volume.
    *   Outputs **NDC coordinates** explicitly to ensure correct depth reconstruction in the Pixel Shader.

2.  **Pixel Shader (`IntervalShadingPS.hlsl`):**
    *   Reconstructs View-Space positions from NDC.
    *   Calculates `FrontDepth`, `BackDepth`, and `OpticalDepth` (Interval Length * Density).
    *   Outputs to 3 Render Targets simultaneously.

3.  **Blending (Order Independence):**
    *   **Front RT:** `MIN` Blending (Retains nearest entry point).
    *   **Back RT:** `MAX` Blending (Retains furthest exit point).
    *   **Optical RT:** `ADD` Blending (Accumulates density).
    *   *Note:* Requires `IndependentBlendEnable = TRUE` in the PSO to mix MIN/MAX/ADD operations.

4.  **Composite Pass (`IntervalCompositePS.hlsl`):**
    *   Fullscreen triangle pass.
    *   Samples the 3 textures to compute `Transmittance = exp(-OpticalDepth)`.
    *   Applies volumetric coloring.

### Key Changes & Fixes
*   **Pipeline Fix:** Enabled `IndependentBlend` to fix the "Black Back Buffer" issue (MAX blending was being ignored).
*   **Data Fix:** Corrected `.vtk` loader to use **0-based indexing** (removing the legacy `-1` offset), fixing the scrambled mesh.
*   **Shader Fix:** Added explicit `NDC` output in Mesh Shader to fix vertex wobbling/artifacts during projection.
*   **Build System:** Configured `.vcxproj` to automatically compile shaders (`FxCompile`) with `dxc.exe` (Shader Model 6.5) into the correct binary directory.
*   **Usability:** Added Camera Pitch controls (Up/Down) and fixed the initial Bunny orientation (flipped upright).

## Building & Running

### Requirements
*   Visual Studio 2019 or 2022.
*   Windows 10/11 SDK (supporting Shader Model 6.5).
*   GPU supporting **DirectX 12 Ultimate (Mesh Shaders)** (e.g., NVIDIA RTX 20/30/40 series, AMD RX 6000+).

### Instructions
1.  Open `Samples\Desktop\D3D12MeshShaders\src\D3D12MeshShaders.sln`.
2.  Set **IntervalShadingTetrahedron** as the StartUp Project.
3.  Select **Debug** or **Release** configuration and **x64**.
4.  **Build Solution** (Shaders will compile automatically).
5.  **Run** (F5).

The sample loads `bunny.vtk` from the `Assets` directory.
