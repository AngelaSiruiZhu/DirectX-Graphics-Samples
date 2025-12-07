# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains the **IntervalShadingTetrahedron** project, a DirectX 12 Mesh Shader sample demonstrating **Interval Shading** for order-independent volumetric rendering. The project renders procedural volumetric clouds and crystal-like objects using tetrahedral meshes.

**Project Location:** `Samples/Desktop/D3D12MeshShaders/src/IntervalShadingTetrahedron/`

Based on the paper: *Interval Shading: using Mesh Shaders to generate shading intervals for volume rendering* (Tricard 2024).

## Build Commands

### Quick Build
```powershell
# Use the project-specific build script
.\Samples\Desktop\D3D12MeshShaders\src\IntervalShadingTetrahedron\build_simple.ps1

# Executable location: Samples/Desktop/D3D12MeshShaders/src/IntervalShadingTetrahedron/bin/runnable.exe
```

### Manual Build
```powershell
# Using MSBuild directly
msbuild "Samples/Desktop/D3D12MeshShaders/src/D3D12MeshShaders.sln" /p:Configuration=Debug /p:Platform=x64 /t:IntervalShadingTetrahedron

# Or open in Visual Studio and build
# Set IntervalShadingTetrahedron as the StartUp Project
```

### Build Configurations
- **Debug** - Full validation layers, slower performance, useful for debugging
- **Release** - Optimized build for performance testing

**Platform:** x64 only

### Shader Compilation
Shaders are automatically compiled during build via FxCompile tasks in the `.vcxproj`:
- Uses `dxc.exe` (DirectX Shader Compiler) for Shader Model 6.5+
- Outputs `.cso` files to `bin/` directory
- Main shaders: `IntervalShadingMS.hlsl`, `IntervalShadingPS.hlsl`, `IntervalCompositePS.hlsl`, `IntervalCompositeVS.hlsl`

## Architecture and Rendering Pipeline

### Two-Pass Rendering System

**Pass 1: Interval Generation (Mesh Shader)**
- **Shader:** `IntervalShadingMS.hlsl`
- **Input:** Tetrahedral mesh from `.vtk` files (vertices + tetrahedra indices)
- **Process:**
  - Near-plane clipping splits tetrahedra into prisms/tets
  - Generates 2D "proxy triangles" covering the screen-space footprint
  - Each vertex encodes Front (entry) and Back (exit) depth in NDC coordinates
- **Output:** 3 render targets simultaneously
  - `FrontRT` (R16_FLOAT) - MIN blend to capture closest entry depth
  - `BackRT` (R16_FLOAT) - MAX blend to capture furthest exit depth
  - `OpticalDepthRT` (R16_FLOAT) - ADD blend to accumulate optical depth

**Pass 2: Volumetric Composition (Full-Screen Pass)**
- **Shaders:** `IntervalCompositeVS.hlsl` + `IntervalCompositePS.hlsl`
- **Process:**
  - Fullscreen triangle covers entire viewport
  - Pixel shader reads Front/Back/OpticalDepth textures
  - **Ray marching** between front and back depth intervals
  - **Procedural density** via 3D FBM noise function
  - **Lighting** with Beer-Lambert law, self-shadowing, and directional light
- **Render Modes:**
  - Modes 0-4: Debug views (Front Depth, Back Depth, Interval Length, Optical Depth, Transmittance)
  - Mode 5: Full volumetric cloud rendering with lighting and god rays
  - Mode 6: Wireframe debug view

### Order Independence

Critical to the technique: Uses `IndependentBlendEnable = TRUE` in the PSO to enable different blend operations per render target:
- FrontRT uses MIN blend
- BackRT uses MAX blend
- OpticalDepthRT uses ADD blend

This allows tetrahedra to be rendered in any order while still producing correct depth intervals.

## Code Structure

### Main Application Files
- **IntervalShadingTetrahedron.h/cpp** - Main application class, rendering pipeline, scene management
- **DXSample.h/cpp** - Base class for window creation and DirectX initialization
- **Win32Application.h/cpp** - Win32 window management and message loop
- **DXSampleHelper.h** - Utility macros (ThrowIfFailed, GetAssetsPath, etc.)

### Key Components in IntervalShadingTetrahedron.cpp

**Scene Loading:**
- `LoadTetrahedralMesh()` - Loads `.vtk` files (ASCII format, 0-based indexing)
- `LoadScene()` - Loads `scene.json` for multi-object scenes with transforms
- Supports multiple mesh instances with position, rotation, scale

**Pipeline State Objects:**
- `BuildIntervalPipelineState()` - Mesh Shader + Pixel Shader for interval generation
- `BuildCompositePipelineState()` - Fullscreen pass for volumetric composition
- `BuildDebugPipelineState()` - Debug rendering modes

**Rendering:**
- `PopulateCommandList()` - Records command list with both passes
- `UpdateConstants()` - Updates per-frame constant buffer (camera, lighting, density)
- `ShuffleTets()` - Randomizes tetrahedra draw order to verify order-independence

### Shader Architecture

**IntervalShadingMS.hlsl:**
- Mesh Shader entry point with near-plane clipping logic
- Outputs up to 128 vertices and 126 triangles per meshlet
- Explicit NDC coordinate output to prevent vertex wobbling
- Per-tetrahedron world matrix transform for multi-object scenes

**IntervalShadingPS.hlsl:**
- Simple pass-through outputting Front/Back/OpticalDepth values
- Reconstructs view-space positions from NDC
- Calculates optical depth as `(BackDepth - FrontDepth) * Density`

**IntervalCompositePS.hlsl:**
- Ray marching implementation with 64 steps
- 3D FBM noise (4 octaves) for heterogeneous density
- Depth fade at mesh boundaries to prevent hard edges
- Directional lighting with phase function and god rays
- Multiple debug visualization modes

### Constant Buffer Layout
```cpp
struct SceneConstantBuffer {
    XMFLOAT4X4 Model;           // Per-object world transform
    XMFLOAT4X4 View;
    XMFLOAT4X4 Proj;
    XMFLOAT4X4 ViewProj;
    XMFLOAT4X4 InvViewProj;     // For depth reconstruction
    float NearPlane;            // For clipping
    float Density;              // Global density multiplier
    uint32_t DebugMode;         // Render mode selector (0-6)
    uint32_t TetCount;          // Number of tetrahedra to render
    uint32_t RandomizeOrder;    // Enable/disable order randomization
    XMFLOAT3 CameraPos;
    float Time;                 // For animation
    XMFLOAT3 LightDir;          // Directional light
    uint32_t TetOffset;         // Offset into global index buffer
};
```

## Scene Configuration

**Format:** JSON file at `Samples/Desktop/D3D12MeshShaders/src/Assets/IntervalShading/scene.json`

**Structure:**
```json
{
    "camera": {
        "position": [x, y, z],
        "target": [x, y, z]
    },
    "light": {
        "direction": [x, y, z],
        "color": [r, g, b],
        "intensity": float
    },
    "objects": [
        {
            "name": "Object Name",
            "mesh": "filename.vtk",
            "position": [x, y, z],
            "rotation": [x, y, z],  // Euler angles in radians
            "scale": [x, y, z]
        }
    ]
}
```

Currently all objects use `cloud_structure.vtk` with different transforms to create a multi-cloud scene.

## Asset Generation

### Procedural Cloud Tool
**Location:** `Samples/Desktop/D3D12MeshShaders/src/Tools/generate_cloud.js`

**Usage:**
```powershell
node Samples/Desktop/D3D12MeshShaders/src/Tools/generate_cloud.js [options]
```

**Key Options:**
- `--mode` - `grid` (connected mesh) or `soup` (disconnected shards for chaotic shapes)
- `--shape` - `chaos`, `storm`, `wispy`, `cumulus` (different noise patterns)
- `--res` - Grid resolution (32, 64, 128+). Higher = more detail, larger files
- `--thresh` - Density threshold (0.2 = denser, 0.4 = sparser with holes)
- `--out` - Output path for `.vtk` file

**Example:**
```powershell
node Samples/Desktop/D3D12MeshShaders/src/Tools/generate_cloud.js --mode soup --shape chaos --res 64 --thresh 0.2 --out Samples/Desktop/D3D12MeshShaders/src/Assets/IntervalShading/my_cloud.vtk
```

**Technical Notes:**
- `grid` mode: Connected voxel mesh using marching tetrahedra, good for solid clouds
- `soup` mode: Probabilistic disconnected tetrahedra, creates floating islands and wisps
- Output is ASCII VTK format with POINTS and CELLS sections
- 0-based indexing (fixed from legacy -1 offset)

## VTK File Format

**Location:** `Samples/Desktop/D3D12MeshShaders/src/Assets/IntervalShading/*.vtk`

**ASCII Format:**
```
# vtk DataFile Version 3.0
Cloud mesh
ASCII
DATASET UNSTRUCTURED_GRID
POINTS <count> float
x y z
x y z
...
CELLS <count> <size>
4 i0 i1 i2 i3
4 i0 i1 i2 i3
...
CELL_TYPES <count>
10
10
...
```
- CELL_TYPE 10 = VTK_TETRAHEDRON
- Indices are 0-based
- Each tetrahedron cell has 4 vertex indices

## Application Controls

| Key | Action |
|-----|--------|
| **1** | Debug View: Front Depth |
| **2** | Debug View: Back Depth |
| **3** | Debug View: Interval Length (Heatmap) |
| **4** | Debug View: Optical Depth |
| **5** | Render Mode: Transmittance (Beer-Lambert) |
| **6** | Render Mode: Fog/Crystal (Full volumetric) |
| **R** | Randomize tetrahedron draw order |
| **Arrow Left/Right** | Rotate camera (Yaw) |
| **Arrow Up/Down** | Rotate camera (Pitch) |
| **W / S** | Zoom In / Out |

## Known Implementation Details

### Critical Pipeline Fix
The PSO must have `IndependentBlendEnable = TRUE` to allow mixing MIN/MAX/ADD blend operations. Without this, the back buffer would remain black as MAX blending would be ignored.

### VTK Loader Fix
The loader uses 0-based indexing for tetrahedral connectivity. Legacy versions incorrectly subtracted 1 from indices, causing scrambled geometry.

### NDC Output Fix
Mesh Shader explicitly outputs NDC coordinates rather than relying on automatic perspective divide. This prevents vertex wobbling and depth artifacts during projection.

### Shader Compilation in vcxproj
All `.hlsl` files are set up with FxCompile build customization:
- Mesh Shaders: `/T ms_6_5`
- Pixel Shaders: `/T ps_6_5`
- Vertex Shaders: `/T vs_6_5`
- Output directory: `bin/`

## Design Documents

**README.md** - User-facing documentation with controls and build instructions
**README_INTERVAL_SHADING.md** - Technical documentation of the rendering pipeline
**README_CLOUDS.md** - Documentation for procedural cloud generation and GPU rendering
**DESIGN_CLOUD_GEN.md** - Retrospective on failed cloud generation experiments (cluster, skeleton, shell modes) and future direction toward hybrid GPU deformation
**BUILD_SCRIPT.md** - Documentation for the PowerShell build script

## Requirements

- **OS:** Windows 10 version 2004+ or Windows 11
- **SDK:** Windows 10 SDK (19041) or later
- **IDE:** Visual Studio 2019 or 2022 with C++ desktop development workload
- **GPU:** DirectX 12 Ultimate capable with Mesh Shader support
  - NVIDIA RTX 20/30/40 series
  - AMD RX 6000+ series
- **Node.js:** Required only for cloud generation tool

## Proactive Behaviors

### Auto-Rebuild
**IMPORTANT:** Whenever C++ files (`.cpp`, `.h`) or shader files (`.hlsl`) are modified, proactively rebuild the project without waiting for the user to ask:

```powershell
powershell -ExecutionPolicy Bypass -File "Samples/Desktop/D3D12MeshShaders/src/IntervalShadingTetrahedron/build_simple.ps1"
```

Rebuild is needed after:
- Pulling latest changes that touch C++/HLSL files
- Editing any `.cpp`, `.h`, or `.hlsl` file
- Changing project configuration

Rebuild is NOT needed for:
- Editing `.vtk` mesh files (loaded at runtime)
- Editing `scene.json` (loaded at runtime)
- Editing `generate_cloud.js` (Node.js tool, not compiled)

### Git Commits
**Do NOT include** the "Generated with Claude Code" or "Co-Authored-By: Claude" footer in commit messages. Keep commits clean and simple.

## Common Development Patterns

### Error Handling
```cpp
ThrowIfFailed(device->CreateCommandQueue(&desc, IID_PPV_ARGS(&m_commandQueue)));
```

### Resource Transitions
```cpp
barrier = CD3DX12_RESOURCE_BARRIER::Transition(
    m_frontRT.Get(),
    D3D12_RESOURCE_STATE_RENDER_TARGET,
    D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
m_commandList->ResourceBarrier(1, &barrier);
```

### Descriptor Heap Indexing
SRV heap layout:
- Index 0: Front RT SRV
- Index 1: Back RT SRV
- Index 2: Optical Depth RT SRV

### Multi-Object Rendering
The application supports multiple mesh instances through:
- `std::vector<MeshData> m_meshes` - Unique mesh geometries
- `std::vector<SceneObject> m_sceneObjects` - Scene instances with transforms
- Per-object constant buffer updates with `TetOffset` for correct index buffer access
