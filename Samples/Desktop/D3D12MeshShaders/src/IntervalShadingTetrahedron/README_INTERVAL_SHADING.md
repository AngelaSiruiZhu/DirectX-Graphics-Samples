# Interval Shading Tetrahedron Sample - Documentation

## Overview

This sample demonstrates a two-pass technique for rendering volumetric effects using **Interval Shading** with DirectX 12 Mesh Shaders. It allows coarse geometry (a tetrahedral mesh) to represent a bounding volume for complex, procedurally generated volumetric data, such as clouds.

## Rendering Pipeline

### Pass 1: Interval Generation (Mesh Shader)
*   **Shader:** `IntervalShadingMS.hlsl`
*   **Input:** Tetrahedral Mesh (`.vtk` file).
*   **Process:** 
    *   Clips tetrahedra against the view frustum.
    *   Generates 2D proxy geometry (triangles) that cover the screen-space footprint of each tetrahedron.
    *   Each vertex encodes the **Front (Entry)** and **Back (Exit)** depth of the tetrahedron.
*   **Output:** 
    *   `FrontRT` (R16_FLOAT): Stores the closest entry depth (using `MIN` blend).
    *   `BackRT` (R16_FLOAT): Stores the furthest exit depth (using `MAX` blend).
    *   `OpticalDepthRT` (R16_FLOAT): Accumulates "optical depth" (thickness * density) using `ADD` blend.

### Pass 2: Volumetric Composition (Pixel Shader)
*   **Shader:** `IntervalCompositePS.hlsl`
*   **Input:** `FrontRT`, `BackRT`, `OpticalDepthRT`, procedural noise, and lighting constants.
*   **Process:**
    *   Executes as a full-screen pass.
    *   Reads the Front and Back depth intervals for each pixel.
    *   **Ray Marching:** Steps through the volume between `Front` and `Back` depths.
    *   **Procedural Density:** Samples a 3D Noise function (FBM) to determine density at each step.
    *   **Lighting:** Calculates self-shadowing and directional lighting.
*   **Modes:**
    *   **0-4 (Debug):** Visualize raw depth buffers, interval length, and simple Beer-Lambert transmittance (based purely on mesh thickness).
    *   **5 (Cloud/Volumetric):** Full volumetric rendering with noise, lighting, and god rays.
    *   **6 (Wireframe):** Debug view showing the wireframe of the tetrahedral mesh.

## Key Concepts

### Density and Transparency
The visual "density" or transparency of the object depends on the rendering mode:

1.  **Uniform Modes (0-4):**
    *   Transparency is determined by **Geometric Thickness**.
    *   `Tau` (Optical Depth) = `(BackDepth - FrontDepth) * GlobalDensity`.
    *   `Transmittance` = `exp(-Tau)`.
    *   Thicker parts of the mesh appear more opaque.
    *   `GlobalDensity` is fixed at `0.8` in `IntervalShadingTetrahedron.cpp`.

2.  **Volumetric Mode (5):**
    *   Transparency is **Heterogeneous** (varying).
    *   The shader performs ray marching and samples a noise function.
    *   `GlobalDensity` acts as a **Frequency Scaler** for the noise, altering the detail level rather than just the opacity.
    *   The final look is a result of accumulated density samples along the ray, creating "clouds" or internal structures.

## Build and Run

*   **Build Script:** `Samples/Desktop/D3D12MeshShaders/src/IntervalShadingTetrahedron/build_simple.ps1`
*   **Executable:** `bin/runnable.exe`
*   **Asset:** Loads `bunny.vtk` by default. Can load other VTK files via code modification or implementing a file picker.

## Controls

*   **W/S:** Zoom In/Out
*   **Arrow Keys:** Rotate Camera
*   **1-6:** Switch Rendering Modes (1:Front, 2:Back, 3:Length, 4:Tau, 5:Transmittance, 6:Cloud)
*   **7:** Wireframe View
*   **R:** Shuffle Tetrahedra Order
*   **O:** Open Mesh File (Not fully implemented/reliable in all contexts)
