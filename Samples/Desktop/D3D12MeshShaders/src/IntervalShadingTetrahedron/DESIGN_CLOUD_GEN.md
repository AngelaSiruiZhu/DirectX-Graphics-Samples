# Cloud Generation Architecture and Evolution

## Current Implementation (Working)

### Generation Pipeline
1. **Offline Generation:** Node.js script `generate_cloud.js` creates tetrahedral meshes
2. **Working Modes:** `structure` and `soup` produce usable cloud shapes
3. **Multi-Cloud Scenes:** `scene.json` defines multiple cloud instances with varied transforms
4. **Runtime Rendering:** Interval Shading with procedural density noise + lighting

### Cloud Meshes Generated
We generated 6 unique cloud meshes (`cloud_1.vtk` through `cloud_6.vtk`) using the `structure` mode with different random seeds. These provide shape variety when placed in scenes with different scales and rotations.

Additional test meshes:
- `cloud_structure.vtk` - Original structure mode output
- `cloud_smooth.vtk`, `cloud_smooth_hires.vtk` - Smoothed variants
- `cloud_multilobe.vtk`, `cloud_multilobe_hires.vtk` - Multi-lobe experiments
- `cloud_cumulus.vtk` - Cumulus-style shape
- Various `test_*.vtk` and `candidate_*.vtk` from experimentation

### Scene Configuration
`scene.json` defines a multi-cloud sky with 25 clouds:
- **Position spread:** X: -48 to +50, Z: -35 to +50
- **Height variation:** Y: 2 to 25
- **Scale variation:** 4.0 to 14.0, with some clouds stretched taller (Y scale up to 14)
- **Rotation variety:** Different Y-axis rotations for visual diversity
- Uses all 6 cloud meshes cycling through

### Shader Tuning
Key parameters tuned for visual quality:

**Light Position:** `float3(0.0, -35.0, 0.0)` - Sun height above clouds

**Light Intensity:** `0.24` - Balanced for visible cloud illumination

**Cloud Density Corrosion:** `0.2` (reduced from 0.4) - Less aggressive erosion for fuller clouds

**God Rays:** Jittered sampling to eliminate banding artifacts

---

## Generation Modes Explained

### Structure Mode (Recommended)
- Creates a warped voxel grid using domain warping
- 16x16x16 base grid at resolution 32
- FBM noise with 5 octaves shapes the density field
- Marching tetrahedra extracts the surface
- **Result:** Connected, watertight mesh with organic shape

### Soup Mode
- Probabilistic disconnected tetrahedra
- Creates floating islands and wisps
- Good for chaotic, broken cloud formations
- Higher performance cost due to many small pieces

---

## Build System

### build.bat Script
Critical fix: MSBuild doesn't always detect shader changes. The `build.bat` script:
1. Touches all `.hlsl` files (updates timestamps)
2. Runs MSBuild
3. Ensures shaders are always recompiled

**Always use `build.bat` instead of calling MSBuild directly.**

---

## Retrospective: Failed Experiments

### 1. Cluster Mode (Abandoned)
- **Concept:** Hundreds of small spherical "puffs" aggregated
- **Result:** "Bag of marbles" - disconnected geometry with mirror-like internal face artifacts

### 2. Skeleton Mode (Abandoned)
- **Concept:** Scatter points, connect nearest neighbors, prune long edges
- **Result:** Too jagged and wireframe-like, lacked billowy roundness

### 3. Shell Mode (Abandoned)
- **Concept:** Surface points with inward extrusion for hollow shell
- **Result:** Non-watertight, sharp hole transitions

---

## Camera System

### Free-Fly Camera
Replaced orbit camera with free-fly for better scene exploration:
- **WASD:** Move relative to view direction (uses view matrix vectors)
- **Arrow Keys:** Look around (yaw/pitch)
- **Starting Position:** Y=-20 (below terrain), looking up at clouds

Implementation extracts actual view vectors from inverse view matrix for accurate movement.

---

## Future Direction

### Hybrid GPU Deformation
The next evolution would move deformation to the Mesh Shader:
1. **CPU:** Upload simple "template mesh" once
2. **GPU:** Apply procedural displacement per-frame
3. **Benefits:** Dynamic morphing, wind effects, no CPU bandwidth overhead

### Alternative: External Tools
Import high-quality meshes from specialized volumetric modeling tools (Houdini, Blender) rather than procedural generation.
