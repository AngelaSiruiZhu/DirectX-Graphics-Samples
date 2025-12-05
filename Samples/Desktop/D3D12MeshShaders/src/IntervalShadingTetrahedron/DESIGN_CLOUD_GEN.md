# Cloud Generation Architecture and Future Direction

## Current Status
*   **Generation Method:** Offline procedural generation via Node.js script (`generate_cloud.js`).
*   **Technique:** "Structure Mode" - Generates a warped tetrahedral grid/sphere.
*   **Result:** A static `.vtk` file loaded at runtime.
*   **Limitation:** The mesh is frozen. Animation is limited to internal density noise, not shape deformation.

## Architectural Proposal: Hybrid Real-Time Generation
To enable real-time shape deformation and interaction, we propose moving the deformation logic to the GPU pipeline.

### The Hybrid Pipeline
1.  **CPU (Initialization Phase):**
    *   Generates a **Base Topology** (connectivity).
    *   This is a coarse, regular structure (e.g., a simple subdivision of a bounding box or sphere into tetrahedra).
    *   Focus is on creating a sufficient "budget" of vertices and tetrahedra, not the final shape.
    *   This "Template Mesh" is uploaded to the GPU once.

2.  **GPU (Mesh Shader Phase):**
    *   Receives the Template Mesh.
    *   **Deformation Kernel:** Applies a procedural displacement function (FBM Noise) to vertices in real-time.
    *   `NewPosition = OriginalPosition + Noise(OriginalPosition + Time) * DistortionStrength`
    *   **Culling:** Can dynamically discard tetrahedra that move outside the view or fall below a density threshold (using `SV_CullPrimitive` or simply outputting 0 triangles).

### Benefits
*   **Dynamic:** Clouds can drift, morph, and react to "wind" parameters instantly.
*   **Efficient:** No CPU-to-GPU bandwidth overhead per frame. Utilizes the Mesh Shader's parallel processing power.
*   **Interactive:** User can tweak noise frequency, amplitude, and speed at runtime.

---

## Future Goal: "Sparse & Freeform" Topology

The current "Warped Grid" approach tends to produce blobby, solid shapes. Real clouds are often sparse, disconnected, and layered.

### Objectives for New Generation Logic
1.  **Lower Density:** Reduce the total tetrahedron count to <10k while maximizing visual volume.
2.  **Freeform Structure:** Break away from the "single connected blob" constraint.
    *   **Stratus:** Flat, layered sheets of tetrahedra.
    *   **Cumulus:** Multiple disconnected clusters ("puffballs").
    *   **Wispy:** Long, stringy chains of tetrahedra.
3.  **Efficiency:** Don't waste tetrahedra on the invisible core of the cloud. Focus geometry on the *shell* (where light interacts) or use "billboard-like" flat tetrahedra for distant wisps.

### Proposed Algorithm: "Hierarchical Cluster planting"
Instead of warping a single grid:
1.  **Plant Seeds:** CPU generates random points within a "cloud domain" (e.g., a box).
2.  **Grow Clusters:** At each seed, generate a small, local cluster of tetrahedra (e.g., a small stellated sphere or a randomized Delaunay group).
3.  **Connect/Prune:** Optionally connect nearby clusters if they overlap, or leave them floating.
4.  **Result:** A "Soup" of coherent chunks. This allows for vast empty spaces (holes) without needing a high-res grid to define "emptiness".

This approach aligns perfectly with the Hybrid model: The CPU plants the "chunks" (topology), and the GPU warps and animates them individually.
