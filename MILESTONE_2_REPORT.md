# Interval Shading Implementation - Milestone 2 Technical Report
**Author:** Crystal Jin  
**Date:** November 24, 2025  
**Topic:** Reimplementation of *Interval Shading: using Mesh Shaders to generate shading intervals for volume rendering* (Tricard 2024)

## 1. Overview
This milestone focuses on the successful reimplementation of the "Interval Shading" technique using DirectX 12 Mesh Shaders. The core goal was to achieve order-independent volume rendering by generating per-pixel depth intervals from a tetrahedral mesh.

The implementation decouples the geometry processing (Mesh Shader) from the shading accumulation (blending), allowing for robust handling of overlapping volumetric elements without strict sorting requirements.

## 2. Core Implementation

### 2.1 Mesh Shader Pipeline (`IntervalShadingMS.hlsl`)
We replaced the traditional Input Assembler -> Vertex Shader -> Geometry Shader pipeline with a modern **Mesh Shader** approach:
*   **Input:** Raw tetrahedral mesh data (Vertices & Indices) loaded from `.vtk` files.
*   **Processing:**
    *   Each Mesh Shader thread group processes a subset of tetrahedra.
    *   **Clipping:** Tetrahedra intersecting the near plane are clipped into smaller primitives (prisms or smaller tets) to avoid rendering artifacts.
    *   **Proxy Geometry:** The shader generates "proxy triangles" representing the front and back faces of the volume.
*   **Output:** Explicit **NDC (Normalized Device Coordinates)** are output directly to ensure precise depth reconstruction in the pixel shader, avoiding interpolation artifacts ("vertex wobbling") observed in early iterations.

### 2.2 Interval Generation & Shading (`IntervalShadingPS.hlsl`)
The pixel shader reconstructs the view-space position of the fragment and calculates three key metrics:
1.  **Front Depth:** Distance to the entry point of the ray into the volume element.
2.  **Back Depth:** Distance to the exit point.
3.  **Optical Depth (Tau):** Calculated as `(BackDepth - FrontDepth) * Density`.

### 2.3 Order-Independent Blending
To achieve order independence without sorting the tetrahedra, we utilized **Independent Logic Blending** across three separate Render Targets (RTs):

| Render Target | Content | Blend Op | Purpose |
| :--- | :--- | :--- | :--- |
| **RT 0** | Front Depth | `MIN` | Stores the *nearest* entry point. |
| **RT 1** | Back Depth | `MAX` | Stores the *furthest* exit point. |
| **RT 2** | Optical Depth | `ADD` | Accumulates total density along the ray. |

*Note: The `MIN` blend for Front Depth works by clearing the RT to `FLT_MAX`. The `MAX` blend for Back Depth clears to `0`.*

### 2.4 Composite Pass
A final fullscreen pass samples the accumulated textures to render the final image:
*   **Transmittance:** `exp(-TotalOpticalDepth)` (Beer-Lambert Law).
*   **Volumetric Fog/Crystal:** Composing the accumulated color based on the interval data.

## 3. Technical Challenges & Solutions

### Issue 1: "Black Back Buffer" (Missing Back Depths)
*   **Symptom:** The Back Depth render target remained black/empty, despite geometry being rasterized.
*   **Root Cause:** The pipeline state was initially configured with a single global blend state. When trying to mix `MIN` (for front) and `MAX` (for back), the API defaults or conflicts caused the second target to be ignored or overwritten.
*   **Solution:** Enabled `IndependentBlendEnable = TRUE` in the Pipeline State Object (PSO). This allows configuring distinct blend operations (`D3D12_BLEND_OP_MIN` vs `D3D12_BLEND_OP_MAX`) for each render target index individually.

### Issue 2: Scrambled Mesh Geometry
*   **Symptom:** The rendered bunny model appeared as a chaotic cloud of triangles rather than a coherent shape.
*   **Root Cause:** The legacy `.vtk` loader assumed 1-based indexing (common in some OBJ/older formats), while the provided assets used 0-based indexing.
*   **Solution:** Updated `IntervalShadingTetrahedron.cpp` loader logic to parse indices directly without the `-1` offset.

### Issue 3: Pipeline Transition Errors
*   **Symptom:** Debug layer errors complaining about `D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE` vs `RENDER_TARGET` mismatches.
*   **Solution:** Implemented a robust `ResourceBarrier` transition system that correctly switches the Interval Render Targets from `RENDER_TARGET` state (during the Mesh Shader pass) to `PIXEL_SHADER_RESOURCE` state (during the Composite pass) and back.

## 4. Development Tools
*   **PowerShell Runner (`Tools/run_interval.ps1`):** A custom script was written to automate the build-and-run process, specifically enabling the D3D12 Debug Layer for rapid iteration and error catching.
*   **Debug Views:** Implemented runtime switching (Keys 1-4) to visualize intermediate buffers (Front/Back/Optical), which was critical for debugging the blending logic.

## 5. Next Steps
*   Implement "Deep Interval Maps" to handle complex overlapping geometry more accurately than a simple Min/Max.
*   Optimize the Mesh Shader clipping algorithm for performance.
