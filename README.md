
<img src="https://github.com/user-attachments/assets/5a5b0054-1f69-4c4a-a28b-99e0cd0ed422" width="75%"/>

# IntervalCloud

**Author:** Crystal Jin, Sirui Zhu, Lijun Qu  
**Date:** December 7, 2025  

This repository contains the **IntervalShadingTetrahedron** project, a DirectX 12 Mesh Shader sample demonstrating **Interval Shading** for order-independent volumetric rendering. The project renders procedural volumetric clouds and crystal-like objects using tetrahedral meshes.

Based on the paper: *Interval Shading: using Mesh Shaders to generate shading intervals for volume rendering* (Tricard 2024).

**Project Location:**  
`Samples/Desktop/D3D12MeshShaders/src/IntervalShadingTetrahedron/`

---

## Overview

Order-independent volumetric renderer built on DX12 mesh shaders that generate per-pixel shading intervals from tetra meshes, then composite soft volumetric clouds with adjustable density, lighting, and screen-space god rays in real time.  
Includes GUI controls, procedural terrain backdrop, and tunable styling parameters to shift between realistic and stylized looks.



### Feature Descriptions

#### **Paper reimplementation (tetra mesh shading)**
Mesh shader loads/clips tetrahedral volume, emits proxy triangles with explicit NDC, and uses MIN/MAX/ADD blending to capture front/back depth and optical depth per pixel without sorting.

#### **Cloud generation**
Ray-marched FBM-based density (base/detail/micro noise), edge fading, and density scaling for soft, puffy clouds; parameters let you thicken, soften, or stylize the look.

#### **Terrain generation**
Procedural ground/sky background with FBM-based heightfield, simple lighting, fog blend, and color layers (grass/dirt/rock/snow) for depth and context.

#### **Deformation**
Time-varying noise drift and density modulation subtly evolve cloud shapes; light-position tweaks and interval padding allow different silhouettes and softness.

#### **God ray light pass**
Screen-space radial sampling toward the light with jitter and decay, modulated by interval coverage and density to produce soft volumetric shafts.

#### **GUI control**
Runtime debug/render mode toggles (depth/interval/optical visualizers, transmittance, fog/crystal), camera controls, density/lighting/god-ray parameters to explore styles and validate order independence.



<table>
<tr>
<td align="center">

<img src="https://github.com/user-attachments/assets/135eeec5-bfe4-4211-adbc-ebd71e093108" width="400"/>

**Realistic Style**

</td>
<td align="center">

<img src="https://github.com/user-attachments/assets/20452776-9c07-4eb4-aa01-ca061239dbbb" width="400"/>

**Cartoon Style**

</td>
</tr>
</table>

### Video Demo

[![Watch the video](https://img.youtube.com/vi/mYOlaZfwEa8/0.jpg)](https://youtu.be/mYOlaZfwEa8)

---

## Build Commands

```bash
# Use the build script - ensures shaders are recompiled
./Samples/Desktop/D3D12MeshShaders/src/IntervalShadingTetrahedron/build.bat

# Executable location: Samples/Desktop/D3D12MeshShaders/src/IntervalShadingTetrahedron/bin/runnable.exe
```

**IMPORTANT:** Always use `build.bat` instead of calling MSBuild directly. MSBuild doesn't always detect shader changes, so the build script touches all `.hlsl` files before building to force recompilation.

---

## Requirements

- **OS:** Windows 10 version 2004+ or Windows 11
- **SDK:** Windows 10 SDK (19041) or later
- **IDE:** Visual Studio 2019 or 2022 with C++ desktop development workload
- **GPU:** DirectX 12 Ultimate capable with Mesh Shader support
  - NVIDIA RTX 20/30/40 series
  - AMD RX 6000+ series
- **Node.js:** Required only for cloud generation tool

---

## Architecture and Rendering Pipeline

### Two-Pass Rendering System

---

### **Pass 1: Interval Generation (Mesh Shader)**

- **Shader:** `IntervalShadingMS.hlsl`
- **Input:** Tetrahedral mesh from `.vtk` files (vertices + tetrahedra indices)

**Process:**
- Near-plane clipping splits tetrahedra into prisms/tets  
- Generates 2D "proxy triangles" covering the screen-space footprint  
- Each vertex encodes Front (entry) and Back (exit) depth in NDC coordinates  

**Output:** 3 render targets simultaneously
- `FrontRT` (R16_FLOAT) - MIN blend to capture closest entry depth  
- `BackRT` (R16_FLOAT) - MAX blend to capture furthest exit depth  
- `OpticalDepthRT` (R16_FLOAT) - ADD blend to accumulate optical depth  

---

### **Pass 2: Volumetric Composition (Full-Screen Pass)**

- **Shaders:** `IntervalCompositeVS.hlsl` + `IntervalCompositePS.hlsl`

**Process:**
- Fullscreen triangle covers entire viewport  
- Pixel shader reads Front/Back/OpticalDepth textures  
- **Ray marching** between front and back depth intervals  
- **Procedural density** via 3D FBM noise function  
- **Lighting** with Beer-Lambert law, self-shadowing, and directional light  

**Render Modes:**
- Modes 0-4: Debug views (Front Depth, Back Depth, Interval Length, Optical Depth, Transmittance)  
- Mode 5: Full volumetric cloud rendering with lighting and god rays  
- Mode 6: Wireframe debug view  

---

## Code Structure

### Main Application Files
- **IntervalShadingTetrahedron.h/cpp** - Main application class, rendering pipeline, scene management  
- **DXSample.h/cpp** - Base class for window creation and DirectX initialization  
- **Win32Application.h/cpp** - Win32 window management and message loop  
- **DXSampleHelper.h** - Utility macros (ThrowIfFailed, GetAssetsPath, etc.)  

---

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

---

## Shader Architecture

### **IntervalShadingMS.hlsl**
- Mesh Shader entry point with near-plane clipping logic  
- Outputs up to 128 vertices and 126 triangles per meshlet  
- Explicit NDC coordinate output to prevent vertex wobbling  
- Per-tetrahedron world matrix transform for multi-object scenes  

### **IntervalShadingPS.hlsl**
- Simple pass-through outputting Front/Back/OpticalDepth values  
- Reconstructs view-space positions from NDC  
- Calculates optical depth as `(BackDepth - FrontDepth) * Density`  

### **IntervalCompositePS.hlsl**
- Ray marching implementation with 64 steps  
- 3D FBM noise (4 octaves) for heterogeneous density  
- Depth fade at mesh boundaries to prevent hard edges  
- Directional lighting with phase function and god rays  
- Multiple debug visualization modes  

---

## Core Features Explainations

### 1. Paper Reimplementation (Tetra Mesh Shading)

Mesh shader loads/clips tetrahedra, emits proxy triangles with explicit NDC; pixel shader captures per-pixel front/back depth and optical depth with MIN/MAX/ADD blending; composite pass ray-marches the interval to shade volume.

**Key Features/Effects:**
- Order-independence: MIN/MAX blends for front/back intersections; ADD for optical depth—no sorting needed.  
- Near-plane clipping: Tetrahedra split into valid prisms/tets to avoid artifacts at the near plane.  
- Explicit NDC output: Stabilizes depth reconstruction in later stages.  
- Interval shading loop: Composite pass reconstructs world positions, smooths intervals, and integrates density/lighting for clouds.  


<img width="1056" height="262" alt="a95ca667c48bc402a645103c1feb58fa" src="https://github.com/user-attachments/assets/68866e1b-b425-4e3e-880e-7547173344f8" />

---

### 2. Cloud Generation

**Location:**  
`Samples/Desktop/D3D12MeshShaders/src/Tools/generate_cloud.js`

**Usage:**
```powershell
node Samples/Desktop/D3D12MeshShaders/src/Tools/generate_cloud.js [options]
```

**Key Options:**
- `--mode` - `grid` (connected mesh) or `soup` (disconnected shards for chaotic shapes)  
- `--shape` - `chaos`, `storm`, `wispy`, `cumulus`  
- `--res` - Grid resolution (32, 64, 128+)  
- `--thresh` - Density threshold (0.2 = denser, 0.4 = sparser with holes)  
- `--out` - Output path for `.vtk` file  

**Example:**
```powershell
node Samples/Desktop/D3D12MeshShaders/src/Tools/generate_cloud.js --mode soup --shape chaos --res 64 --thresh 0.2 --out Samples/Desktop/D3D12MeshShaders/src/Assets/IntervalShading/my_cloud.vtk
```

---

### 3. Deformation

Time-varying FBM noise (base/detail/micro) modulates density to make clouds drift, billow, and subtly reshape.  
Edge handling via coverage-aware fades and interval padding to soften silhouettes or keep them tighter.

**Key Parameters/Effects:**
- Noise scales & time factors (FBM octaves) — adjust drift speed and micro detail  
- `fadeWidthBase`, edge exponent — control softness of cloud boundaries  
- `densityScale` — overall bulk; higher = thicker, darker cores  
- Interval padding — expands/contracts near/far bounds to smooth silhouettes  

---

### 4. God Ray Light Pass

Screen-space radial sampling toward the light; jittered taps with decay to keep shafts soft.

**Key Parameters/Effects:**
- `density`, `weight`, `decay` — strength and softness of shafts  
- Coverage/density sampling — attenuates rays through thick volume, boosts through gaps  
- Distance attenuation to light — tempers ray brightness with depth  
- Sun hotspot exponent/intensity — controls halo size and brightness around the light

<table>
<tr>
<td align="center">

<img src="https://github.com/user-attachments/assets/0572432a-ba82-4230-aec2-5370f951edf0" width="400"/>

</td>
<td align="center">

<img src="https://github.com/user-attachments/assets/6bd34b30-3923-4624-83a6-94aa3c352dd3" width="400"/>


</td>
</tr>
</table>

---

### 5. Terrain Generation

Procedural sky/ground with FBM-based heightfield, simple lighting, fog blend, and layered albedo (grass/dirt/rock/snow).

**Key Parameters/Effects:**
- `groundBaseHeight`, `terrainAmp` — base plane and relief amplitude  
- FBM noise scale (`fbm2D` inputs) — controls terrain roughness  
- Layer blends (grass/dirt/rock/snow thresholds) — shifts surface look and snowline  
- Light vector (`float3(0.5,-1,-0.5)`) — affects shading on slopes  
- Fog factor (`exp(-t * 0.005)`) — blends ground into horizon  

---

### 6. GUI Cloud Control Window

A Win32 “Cloud Controls” window with sliders and labels to tweak cloud rendering at runtime; toggle visibility via the app’s debug/back key handling.

**Key Controls/Effects:**
- Cloud Count: Adjust how many clouds render (`m_numCloudsVisible`), culling the draw loop accordingly.  
- Drift Speed: Scales time-varying FBM drift for cloud motion; affects per-cloud speed and amplitude.  
- Deformation Amount: Scales wave amplitude/speed for procedural deformation, changing silhouette motion.  
- Cloud Density: Scales `m_cloudDensity`, passed into the constant buffer to thicken or lighten clouds.  

Values sync to labels in `UpdateGUIValues`; sliders are initialized with sensible ranges  
(e.g., density 0.10–2.00, drift 0–10.00, deformation 0–3.00, cloud count 1–25).

![d188d9b4f7e5a1f4f8d412fdcf2a4dbf](https://github.com/user-attachments/assets/8995d9dc-9f9a-41af-a232-41248135eb72)

---
