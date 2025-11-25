
<img width="1056" height="262" alt="a95ca667c48bc402a645103c1feb58fa" src="https://github.com/user-attachments/assets/68866e1b-b425-4e3e-880e-7547173344f8" />

# IntervalCloud – Milestone 2 Report

**Author:** Crystal Jin, Sirui Zhu, Lijun Qu
**Date:** November 24, 2025  
A mesh-shader-based interval shading framework for real-time animated volumetric rendering*  
(A reimplementation and extension of *Interval Shading: Using Mesh Shaders to Generate Shading Intervals for Volume Rendering*, Tricard 2024)

## 1. Overview
This milestone delivers a complete reimplementation of the **Interval Shading** technique using **DirectX 12 Mesh Shaders**, generating order-independent per-pixel depth intervals from a tetrahedral mesh for volume rendering.

The system is extended into **IntervalCloud**, which supports:

- Real-time volumetric cloud rendering  
- Procedural noise-based density fields  
- Physically-based lighting and scattering  
- Interactive volumetric deformation  
- A meshlet-inspired acceleration structure for high-parallel processing

<p align="center">
  <img src="https://github.com/user-attachments/assets/021dd7af-ff93-4465-a854-12102e1ddeae" alt="a30a6fe2734f14351797354aa9592f66" width="30%" />
  <img src="https://github.com/user-attachments/assets/c4f9be39-3e28-4eb1-823d-b40440abaff7" alt="af5febd550e3906c8132e6f63e09315c" width="30%" />
  <img src="https://github.com/user-attachments/assets/dac910b2-6669-492a-b969-cb4840ab05f0" alt="a8220393b86cde8375fadad5d06514af" width="30%" />
</p>

## 2. Core Implementation

### 2.1 Mesh Shader Pipeline (`IntervalShadingMS.hlsl`)
The legacy IA → VS → GS pipeline is replaced with a modern **Mesh Shader** pipeline:

**Input**
- Raw tetrahedral mesh: vertices + indices from `.vtk`

**Processing**
- Each mesh shader workgroup processes multiple tetrahedra  
- Near-plane clipping converts partially visible tets into prismoids  
- Proxy triangles encode depth intervals  
- Explicit **NDC-space outputs** ensure stable depth reconstruction  

**Output**
- Triangles encoding `(FrontDepth, BackDepth)` for each pixel

### 2.2 Interval Generation & Shading (`IntervalShadingPS.hlsl`)
For each rasterized fragment:

- **Front Depth** — entry point of the camera ray  
- **Back Depth** — exit point  
- **Optical Depth (Tau)** = `(Back – Front) × Density`

The pixel shader reconstructs view-space depth analytically, avoiding ray marching unless needed by cloud extensions.

<p align="center">
  <img src="https://github.com/user-attachments/assets/0abf3a8b-7604-458e-88f2-ce532aa7d3f7" alt="5a5b6ff7af73a80c5c5dfab1895692bb" width="30%" />
  <img src="https://github.com/user-attachments/assets/5d29894c-aaeb-4afb-834a-2d696d5e4777" alt="314af9a5179a0f1a4ab62d7869fef3b2" width="30%" />
  <img src="https://github.com/user-attachments/assets/99852411-14e6-408d-ae1b-bfdc4de052e2" alt="dd93b5290382432734244891f86f01c0" width="30%" />
</p>



### 2.3 Order-Independent Blending
To aggregate contributions without sorting:

| Render Target | Content | Blend Op | Purpose |
| --- | --- | --- | --- |
| RT0 | Front Depth | `MIN` | First intersection |
| RT1 | Back Depth | `MAX` | Last intersection |
| RT2 | Optical Depth | `ADD` | Accumulated density |

This uses **Independent Blend States** in the PSO (`IndependentBlendEnable = TRUE`).

### 2.4 Composite Pass
A fullscreen pass evaluates:

- **Transmittance:** `exp(-OpticalDepth)` (Beer–Lambert Law)  
- **Volumetric Fog/Crystal** appearance from interval data  

## 3. Technical Enhancements

### 3.1 Meshlet-Like Parallelization Structure (Slide 34–35)
To scale interval generation:

1. **Increased Workgroup Size**  
   - Upgraded from `[numthreads(1,1,1)]` → `[numthreads(16,1,1)]`  
   - Each workgroup processes **16 tetrahedra in parallel**

2. **Wave Intrinsics for Memory Layout**  
   - Solve branch divergence & memory inconsistency issues described in the original paper  
   - Threads compute collective offsets before writing  
   - Entire GPU wave shares results → near-optimal parallel throughput  

This greatly accelerates interval generation.

### 3.2 Cloud 1.0 – Interval-Accelerated Ray Marching
<img width="625" height="461" alt="af5febd550e3906c8132e6f63e09315c" src="https://github.com/user-attachments/assets/5676d3d9-2113-4b91-939d-ea6b73c050ed" />

The mesh shader provides the *exact* front/back depth for the cloud, allowing **ray marching only within the occupied interval**, massively reducing empty-space steps.

Components:

1. **Ray Marching Between Intervals**  
   - March only from `z_front → z_back`, never outside the cloud volume  

2. **Procedural fBM Noise**  
   - Animated to simulate breathing, drifting, erosion

3. **Lighting + Self-Shadowing**  
   - Secondary march toward the light  
   - Directional + ambient lighting  
   - **Powder Effect** simulating bright cloud rims  

### 3.3 Cloud 2.0 – Physically Based Volumetric Cloud Model
<img width="549" height="422" alt="a8220393b86cde8375fadad5d06514af" src="https://github.com/user-attachments/assets/dd825e7c-ad9f-4ccd-9403-2ae53cd5e5e4" />

A more realistic cloud pipeline:

#### Procedural Density
- fBM cloud density field  
- Dense areas → opaque & bright  
- Thin areas → transparent  

#### Beer–Lambert Attenuation
As a ray travels through the volume, it gradually loses energy because the medium absorbs and scatters light. The farther it travels through dense regions, the dimmer it becomes. This accumulated “fading” along the ray is what gives volumetric objects their softness and depth.

#### Single Scattering (Physically Based)
At each point inside the volume, some of the incoming light from the source gets scattered toward the camera. How bright this scattered light appears depends on:
- how much light from the source actually reaches that point (after traveling through the medium),
- the direction relationship between the light and the view (the phase function),
- and the medium’s density at that location.
This scattered contribution, combined with the gradual attenuation, creates realistic lighting inside clouds, fog, or translucent materials.

#### Henyey–Greenstein Phase Function
- Forward-biased (g ≈ 0.85)
- Soft backscatter addition
- Produces strong rim lighting & natural cloud glow

### 3.4 Next Steps
- Higher-resolution and more realistic cloud structures  
- Volumetric light shafts (God rays)  
- Enhanced interactive deformation tools  
- Procedural cloud presets & artist-friendly controls  

## 4. Technical Challenges & Solutions

### Issue 1: Missing Back Depths (“Black Buffer”)
**Cause:** Shared blend state prevented mixed MIN/MAX settings  
**Fix:** Enabled **Independent Logic Blending**

### Issue 2: Scrambled Geometry
**Cause:** VTK loader assumed 1-based indexing  
**Fix:** Updated loader to use proper 0-based indices  

### Issue 3: Resource State Mismatches
**Fix:** Added robust `ResourceBarrier` transitions for RT → SRV → RT reuse  

## 5. Development Tools
- **PowerShell Runner (`Tools/run_interval.ps1`)**  
  Automates build/run with D3D12 Debug Layer  
- **Debug View Modes (1–4)**  
  Visualize Front, Back, Interval Length, Optical Depth  

## 6. Summary
This milestone fully reimplements Interval Shading in DX12, integrates a meshlet-style pipeline for high-parallel tetrahedral processing, and extends the system into a real-time volumetric cloud renderer featuring:

- Procedural density  
- Interval-accelerated ray marching  
- Physically based lighting  
- Interactive volumetric deformation  

The result is a fast, accurate, artist-friendly volumetric rendering framework suitable for real-time applications.
