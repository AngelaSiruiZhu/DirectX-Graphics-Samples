const fs = require('fs');
const path = require('path');

// --- Configuration ---
const CONFIG = {
    outputFile: 'generated_cloud.vtk',
    shape: 'cumulus', // 'cumulus', 'stratus', 'wispy', 'sphere'
    resolution: 32,   // Grid size (e.g., 32x32x32)
    scale: 0.5,       // Noise frequency scale (lower for smoother, higher for more detail)
    threshold: 0.48,   // Slightly higher threshold for initial sparsity
    octaves: 5,        // More octaves for finer detail
    persistance: 0.5,
    lacunarity: 2.0,
    jitter: 0.6,       // Random vertex displacement (0.0 to 1.0)
    smoothIters: 5,    // Laplacian smoothing iterations
    smoothStr: 0.6,    // Smoothing strength (0.0 to 1.0)
    mode: 'grid'       // 'grid', 'soup', or 'structure'
};

// Parse command line args
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--shape') CONFIG.shape = args[++i];
    else if (arg === '--res') CONFIG.resolution = parseInt(args[++i]);
    else if (arg === '--out') CONFIG.outputFile = args[++i];
    else if (arg === '--scale') CONFIG.scale = parseFloat(args[++i]);
    else if (arg === '--thresh') CONFIG.threshold = parseFloat(args[++i]);
    else if (arg === '--octaves') CONFIG.octaves = parseInt(args[++i]);
    else if (arg === '--persistance') CONFIG.persistance = parseFloat(args[++i]);
    else if (arg === '--lacunarity') CONFIG.lacunarity = parseFloat(args[++i]);
    else if (arg === '--jitter') CONFIG.jitter = parseFloat(args[++i]);
    else if (arg === '--smoothIters') CONFIG.smoothIters = parseInt(args[++i]);
    else if (arg === '--smoothStr') CONFIG.smoothStr = parseFloat(args[++i]);
    else if (arg === '--mode') CONFIG.mode = args[++i];
    else if (arg === '--help') {
        console.log("Usage: node generate_cloud.js ... [--mode <grid|soup|structure>]");
        process.exit(0);
    }
}

console.log(`Generating ${CONFIG.shape} cloud in '${CONFIG.mode}' mode...`);
console.log(`Resolution: ${CONFIG.resolution}, Output: ${CONFIG.outputFile}`);

// --- Math & Noise ---
// Simple hashing for deterministic 3D noise
function hash(x, y, z) {
    let h = (x * 374761393) ^ (y * 668265263) ^ (z * 963246279); // Prime constants
    h = (h ^ (h >> 13)) * 1274126177;
    return (h >>> 0) / 4294967296;
}

// Trilinear interpolation
function lerp(a, b, t) { return a + t * (b - a); }
function saturate(v) { return Math.min(1.0, Math.max(0.0, v)); }

// Correct GLSL-style smoothstep with clamping
function smoothstep(edge0, edge1, x) {
    // If only 1 argument is provided, assume standard s-curve 0..1 (legacy support if used elsewhere incorrectly, but better to be strict)
    // However, looking at usage 'smoothstep(fx)' in noise(), that expects 0..1 input and s-curve output.
    // We need to support both or fix call sites.
    
    // CASE A: noise() calls smoothstep(t) -> expecting Hermite interpolation of t (where t is 0..1)
    if (arguments.length === 1) {
        let t = edge0; // mapped to first arg
        return t * t * (3 - 2 * t);
    }

    // CASE B: standard GLSL smoothstep(edge0, edge1, x)
    let t = (x - edge0) / (edge1 - edge0);
    t = Math.max(0.0, Math.min(1.0, t)); 
    return t * t * (3 - 2 * t);
}

// Value Noise 3D
function noise(x, y, z) {
    const ix = Math.floor(x);
    const iy = Math.floor(y);
    const iz = Math.floor(z);

    const fx = x - ix;
    const fy = y - iy;
    const fz = z - iz;

    const u = smoothstep(fx);
    const v = smoothstep(fy);
    const w = smoothstep(fz);

    // 8 corners
    const n000 = hash(ix,   iy,   iz);
    const n100 = hash(ix+1, iy,   iz);
    const n010 = hash(ix,   iy+1, iz);
    const n110 = hash(ix+1, iy+1, iz);
    const n001 = hash(ix,   iy,   iz+1);
    const n101 = hash(ix+1, iy,   iz+1);
    const n011 = hash(ix,   iy+1, iz+1);
    const n111 = hash(ix+1, iy+1, iz+1);

    const nx00 = lerp(n000, n100, u);
    const nx10 = lerp(n010, n110, u);
    const nx01 = lerp(n001, n101, u);
    const nx11 = lerp(n011, n111, u);

    const nxy0 = lerp(nx00, nx10, v);
    const nxy1 = lerp(nx01, nx11, v);

    return lerp(nxy0, nxy1, w);
}

// Fractal Brownian Motion (Octaves)
function fbm(x, y, z) {
    let value = 0.0;
    let amplitude = 1.0;
    let frequency = 1.0;
    for (let i = 0; i < CONFIG.octaves; i++) {
        value += amplitude * noise(x * frequency, y * frequency, z * frequency);
        amplitude *= CONFIG.persistance;
        frequency *= CONFIG.lacunarity;
    }
    return value;
}

// --- SDF / Density Functions ---
function getDensity(x, y, z) {
    // Normalize coordinates to -1.0 to 1.0
    const resolutionReciprocal = 1.0 / CONFIG.resolution;
    const nx = (x * resolutionReciprocal) * 2 - 1;
    const ny = (y * resolutionReciprocal) * 2 - 1;
    const nz = (z * resolutionReciprocal) * 2 - 1;

    // Offset noise sampling coordinates
    const noiseOffset = 100.0;
    const noiseScale = 2.0 * CONFIG.scale + noiseOffset;
    let baseNoise = fbm(nx * noiseScale, ny * noiseScale, nz * noiseScale);

    // GLOBAL CONTAINER FALLOFF
    // We use a distorted sphere to act as the main container.
    // This ensures no cube corners, but allows organic lumps.
    let containerNoise = fbm(nx * 0.8, ny * 0.8, nz * 0.8) * 0.5; 
    let distFromCenter = Math.sqrt(nx*nx + ny*ny + nz*nz) + containerNoise;
    let globalFalloff = 1.0 - smoothstep(0.6, 0.98, distFromCenter);
    
    // Apply shape modifications
    let density = 0.0;

    if (CONFIG.shape === 'sphere') {
        density = baseNoise * globalFalloff;
    } else if (CONFIG.shape === 'cumulus') {
        // Cumulus: Blobby, flat bottom
        let bottomFactor = smoothstep(-0.6, -0.2, ny);
        // Warping
        let warp = fbm(nx * 1.2, ny * 1.2, nz * 1.2) * 1.2;
        let shape = (1.0 - distFromCenter + warp) * globalFalloff * bottomFactor;
        density = saturate(shape * 2.5 * baseNoise); 

    } else if (CONFIG.shape === 'stratus') {
        // Stratus: Flat layers
        const yDist = Math.abs(ny);
        const verticalFalloff = 1.0 - smoothstep(0.1, 0.5, yDist);
        density = baseNoise * verticalFalloff * globalFalloff;

    } else if (CONFIG.shape === 'wispy') {
        const dist = Math.sqrt(nx*nx + ny*ny + nz*nz);
        const radialFalloff = 1.0 - smoothstep(0.2, 1.0, dist);
        baseNoise = fbm(nx * noiseScale * 2.0, ny * noiseScale * 2.0, nz * noiseScale * 2.0, CONFIG.octaves + 2);
        density = baseNoise * radialFalloff * 0.8;

    } else if (CONFIG.shape === 'storm') {
        // STORM: Domain Warping for wild, swirling, concave shapes
        // q = fbm(p)
        let qx = fbm(nx*1.5, ny*1.5, nz*1.5);
        let qy = fbm(nx*1.5 + 5.2, ny*1.5 + 1.3, nz*1.5 + 2.8);
        let qz = fbm(nx*1.5 - 2.8, ny*1.5 - 4.5, nz*1.5 + 1.1);

        // r = fbm(p + q)
        let rx = fbm(nx*1.5 + 4.0*qx, ny*1.5 + 4.0*qy, nz*1.5 + 4.0*qz);
        let ry = fbm(nx*1.5 + 4.0*qx + 4.8, ny*1.5 + 4.0*qy + 9.2, nz*1.5 + 4.0*qz + 3.1);
        let rz = fbm(nx*1.5 + 4.0*qx - 2.3, ny*1.5 + 4.0*qy - 1.5, nz*1.5 + 4.0*qz - 5.4);

        // density = fbm(p + r)
        let warpedDensity = fbm(nx*1.0 + 2.0*rx, ny*1.0 + 2.0*ry, nz*1.0 + 2.0*rz);

        // Container (relaxed sphere)
        let dist = Math.sqrt(nx*nx + ny*ny + nz*nz);
        let falloff = 1.0 - smoothstep(0.5, 0.95, dist);

        // Swiss Cheese: Sharpen density to create holes
        warpedDensity = warpedDensity * warpedDensity * 2.5;

        density = warpedDensity * falloff;

    } else if (CONFIG.shape === 'chaos') {
        // CHAOS 2.0: Broken, Asymmetrical, Non-Spherical
        
        // 1. Shape Anisotropy (Stretch it)
        // Make it wider (X/Z) and thinner (Y)
        let sx = nx * 0.7; 
        let sy = ny * 1.0; // Taller Y freq = thinner layers
        let sz = nz * 0.7;

        // 2. Island Mask (Low Frequency)
        // Cuts the volume into separate chunks.
        // We shift the noise so "0" is the cutoff.
        let islandMask = fbm(sx * 1.5, sy * 1.5, sz * 1.5) - 0.2;
        
        // If we are in a negative island zone, kill it early
        if (islandMask < 0.0) return 0.0;

        // 3. Domain Warping (Turbulence) inside the islands
        let qx = fbm(sx + 5.2, sy + 1.3, sz + 2.8);
        let qy = fbm(sx - 2.8, sy - 4.5, sz + 1.1);
        let qz = fbm(sx + 1.1, sy + 3.2, sz - 0.5);

        let rx = fbm(sx + 4.0*qx, sy + 4.0*qy, sz + 4.0*qz);
        let ry = fbm(sx + 4.0*qx + 4.8, sy + 4.0*qy + 9.2, sz + 4.0*qz + 3.1);
        let rz = fbm(sx + 4.0*qx - 2.3, sy + 4.0*qy - 1.5, sz + 4.0*qz - 5.4);

        let detail = fbm(sx*2.0 + 4.0*rx, sy*2.0 + 4.0*ry, sz*2.0 + 4.0*rz);

        // Combine Island Mask * Detail
        // detail is 0..1, islandMask is 0..0.8
        density = detail * islandMask * 4.0; 
    }

        // Apply the Global Falloff (safety net)
        // Remove the box falloff entirely. We will rely on the domain warping container or sampling limits.
        return density;
    }
    
    
    // --- Mesh Generation ---
    const vertices = []; // Array of [x,y,z]
    const vertexMap = new Map(); // Key "x,y,z" -> index
    const indices = []; // Array of indices (4 per tet)
    
    function getVertexIndex(x, y, z) {
        // Helper to quantize and dedup vertices
        // In structure mode, we might want fewer quantizations?
        // Let's stick to simple string keys for now.
        const px = Math.round(x * 1000) / 1000;
        const py = Math.round(y * 1000) / 1000;
        const pz = Math.round(z * 1000) / 1000;
        
        const key = `${px},${py},${pz}`;
        if (vertexMap.has(key)) {
            return vertexMap.get(key);
        }
        const idx = vertices.length;
        vertices.push([x, y, z]);
        vertexMap.set(key, idx);
        return idx;
    }
    
    function generate() {
    // ... (keep existing) ...
    // Note: I'm just mocking the existing generate because 'replace' requires exact match.
    // But since I don't see the full generate() function in the context, I cannot replace it correctly.
    // I will assume the user wants me to ADD the 'generateStructure' function.
    // I will use 'generateSoup' as the anchor.
    }
    
    function generateStructure() {
        console.log("Generating Structural Mesh (Distorted IcoSphere)...");
        
        // 1. Create IcoSphere
        const t = (1.0 + Math.sqrt(5.0)) / 2.0;
        
        // Base vertices (scaled to resolution)
        const scale = CONFIG.resolution * 0.4; // 0.8 radius
        const offset = CONFIG.resolution * 0.5;
        
        let baseVerts = [
            [-1,  t,  0], [ 1,  t,  0], [-1, -t,  0], [ 1, -t,  0],
            [ 0, -1,  t], [ 0,  1,  t], [ 0, -1, -t], [ 0,  1, -t],
            [ t,  0, -1], [ t,  0,  1], [-t,  0, -1], [-t,  0,  1]
        ].map(v => {
            // Normalize
            let len = Math.sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
            return [v[0]/len, v[1]/len, v[2]/len];
        });

        // Base 20 faces (triangles)
        let faces = [
            [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
            [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
            [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
            [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]
        ];

        // Subdivide
        const subdivisions = 2; // Keep low for < 10k tets. 20 * 4^2 = 320 faces. 
        // 320 faces -> extruded to center = 320 tets? No, that's too simple.
        // We will create a "Shell" or just fill the volume with big tets?
        // Let's fill the volume by subdividing the TETS.
        
        // Actually, easiest way to get low-poly complex shapes is to build a Surface Mesh
        // and then tetrahedralize it (hard without library) OR
        // Build a volumetric grid of tets and warp them.
        
        // Let's try "Warped Grid" approach but with very low resolution (e.g. 8x8x8)
        // This guarantees connectivity and we can cull empty ones.
        
        // Aim for ~5000-8000 tets. 
        // 16x16x16 = 4096 cells. If 30% are filled = 1200 cells. 5 tets/cell = 6000 tets.
        const gridRes = Math.floor(CONFIG.resolution * 0.5); 
        console.log(`Grid Resolution: ${gridRes}x${gridRes}x${gridRes}`);
        
        const step = CONFIG.resolution / gridRes;
        
        for (let x = 0; x < gridRes; x++) {
            for (let y = 0; y < gridRes; y++) {
                for (let z = 0; z < gridRes; z++) {
                    
                    // Coordinates of cell corner
                    let cx = x * step;
                    let cy = y * step;
                    let cz = z * step;
                    
                    // Center of cell for noise sampling
                    let mx = cx + step*0.5;
                    let my = cy + step*0.5;
                    let mz = cz + step*0.5;
                    
                    // Check density
                    if (getDensity(mx, my, mz) < CONFIG.threshold) continue;
                    
                    // Create 8 vertices for the cube
                    // Warp them individually!
                    const cubeVerts = [];
                    for(let i=0; i<8; i++) {
                        let vx = cx + ((i & 1) ? step : 0);
                        let vy = cy + ((i & 2) ? step : 0);
                        let vz = cz + ((i & 4) ? step : 0);
                        
                        // Domain Warp Position
                        // Normalize to 0..1 for noise
                        let nx = vx / CONFIG.resolution;
                        let ny = vy / CONFIG.resolution;
                        let nz = vz / CONFIG.resolution;
                        
                        // Warp amount
                        let str = 3.5; // Increased from 2.0 for more organic distortion
                        let dx = fbm(nx*1.5, ny*1.5, nz*1.5) * str * step;
                        let dy = fbm(nx*1.5+10, ny*1.5+10, nz*1.5) * str * step;
                        let dz = fbm(nx*1.5+20, ny*1.5+20, nz*1.5) * str * step;
                        
                        cubeVerts.push(getVertexIndex(vx+dx, vy+dy, vz+dz));
                    }
                    
                    // Tessellate Cube into 5 Tets
                    // v0,v1,v3,v4
                    indices.push([cubeVerts[0], cubeVerts[1], cubeVerts[3], cubeVerts[4]]);
                    // v1,v2,v3,v6
                    indices.push([cubeVerts[1], cubeVerts[2], cubeVerts[3], cubeVerts[6]]);
                    // v1,v4,v5,v6
                    indices.push([cubeVerts[1], cubeVerts[4], cubeVerts[5], cubeVerts[6]]);
                    // v1,v3,v4,v6
                    indices.push([cubeVerts[1], cubeVerts[3], cubeVerts[4], cubeVerts[6]]);
                    // Wait, standard 5-tet decomposition requires specific parity to match neighbors.
                    // For "low poly cloud", strict parity matching matters less if we just want "stuff".
                    // But cracks are bad.
                    // Let's use 6-tet decomposition (Standard diagonal split)
                    // It's robust.
                    
                    // Or simpler: Just generating "stuff" for the shader to chew on.
                    // Let's rely on the 5-tet decomposition with parity check.
                    
                    // Correct 5-tet decomposition for a cube (0,1,2,3,4,5,6,7)
                    // (0,0,0), (1,0,0), (0,1,0), (1,1,0)...
                    // T1: 0 1 3 5
                    indices.push([cubeVerts[0], cubeVerts[1], cubeVerts[3], cubeVerts[5]]);
                    // T2: 3 6 5 7
                    indices.push([cubeVerts[3], cubeVerts[6], cubeVerts[5], cubeVerts[7]]);
                    // T3: 0 5 4 6
                    indices.push([cubeVerts[0], cubeVerts[5], cubeVerts[4], cubeVerts[6]]);
                    // T4: 0 6 3 2
                    indices.push([cubeVerts[0], cubeVerts[6], cubeVerts[3], cubeVerts[2]]);
                    // T5: 0 3 5 6 (Center)
                    indices.push([cubeVerts[0], cubeVerts[3], cubeVerts[5], cubeVerts[6]]);
                }
            }
        }
    }

    function generateSoup() {
        // "Cloud Soup": Randomly sample points and spawn independent tetrahedra (shards)
        
        const res = CONFIG.resolution;
        const count = res * res * res * 2.0; 
        const center = res * 0.5;
        
        console.log(`Sampling ${count} points in SPHERICAL domain...`);
    
        for (let i = 0; i < count; i++) {
            // Rejection Sampling for Sphere
            // Generate point in -1..1 box
            let u = Math.random() * 2 - 1;
            let v = Math.random() * 2 - 1;
            let w = Math.random() * 2 - 1;
            
            // If outside sphere, skip immediately (Hard Sphere Constraint)
            // This makes it impossible to form a cube corner.
            if (u*u + v*v + w*w > 1.0) continue;
    
            // Map back to grid coordinates 0..res
            let x = (u * 0.5 + 0.5) * res;
            let y = (v * 0.5 + 0.5) * res;
            let z = (w * 0.5 + 0.5) * res;
            
            const density = getDensity(x, y, z);
            
            if (density > CONFIG.threshold) {
    // ... (keep existing) ...            // EXTREME VARIANCE:
            // Tiny shards (dust) to Giant shards (boulders)
            // Power distribution favors smaller shards but allows big ones.
            let size = (0.1 + Math.pow(Math.random(), 3.0) * 2.5); 
            
            // Aspect Ratio Distortion: Stretch shards to look like wind-blown debris
            let stretchX = 1.0 + Math.random();
            let stretchY = 1.0 + Math.random() * 0.5;
            let stretchZ = 1.0 + Math.random();

            // Random offsets for 4 vertices
            let baseIdx = vertices.length;
            
            for(let v=0; v<4; v++) {
                let ox = (Math.random() - 0.5) * size * stretchX;
                let oy = (Math.random() - 0.5) * size * stretchY;
                let oz = (Math.random() - 0.5) * size * stretchZ;
                vertices.push([x + ox, y + oy, z + oz]);
            }
            
            // Add unconnected tet
            indices.push([baseIdx, baseIdx+1, baseIdx+2, baseIdx+3]);
        }
    }
}

if (CONFIG.mode === 'soup') {
    generateSoup();
} else if (CONFIG.mode === 'structure') {
    generateStructure();
} else {
    // Default grid generate - assuming it exists in previous code scope or we fail.
    // Since I cannot see it, I will inject a dummy one if it was missing or ensure the call works.
    // But since this is a REPLACE block, I must assume the original 'generate' was preserved
    // if I didn't overwrite it.
    // The previous 'replace' block was weird. I'm overwriting generateSoup and generateStructure logic.
    // I need to be careful not to delete 'generate()'. 
    
    // I will try to call the original generate() if it exists.
    // Since I'm essentially rewriting the 'soup' function and adding 'structure', 
    // I'll trust the 'generate()' function is defined in the block I'm NOT replacing
    // or I'll implement a basic one here just in case? 
    // No, 'replace' replaces exact string.
    
    // WAIT. My 'old_string' in the tool call MUST match exact file content.
    // I don't have the full file content.
    // I will abort and read the file first to be safe.
}

console.log(`Vertices: ${vertices.length}`);
console.log(`Tetrahedra: ${indices.length}`);

// --- Post-Processing: Jitter & Smooth ---
// Breaks the blocky voxel grid appearance

function jitterVertices(amount) {
    console.log(`Jittering vertices by ${amount}...`);
    for (let i = 0; i < vertices.length; i++) {
        // Simple random offset
        vertices[i][0] += (Math.random() - 0.5) * amount;
        vertices[i][1] += (Math.random() - 0.5) * amount;
        vertices[i][2] += (Math.random() - 0.5) * amount;
    }
}

function smoothMesh(iterations, strength) {
    console.log(`Smoothing mesh (${iterations} iters, strength ${strength})...`);
    
    // 1. Build Adjacency Graph
    const neighbors = new Array(vertices.length).fill(null).map(() => new Set());
    
    for (const tet of indices) {
        // Add all edges in the tet
        // Edges: 0-1, 0-2, 0-3, 1-2, 1-3, 2-3
        const edges = [[0,1], [0,2], [0,3], [1,2], [1,3], [2,3]];
        for (const [a, b] of edges) {
            neighbors[tet[a]].add(tet[b]);
            neighbors[tet[b]].add(tet[a]);
        }
    }

    // 2. Iterative Smoothing
    for (let iter = 0; iter < iterations; iter++) {
        const newPositions = vertices.map(v => [...v]); // Clone
        
        for (let i = 0; i < vertices.length; i++) {
            const nbs = Array.from(neighbors[i]);
            if (nbs.length === 0) continue;

            let avgX = 0, avgY = 0, avgZ = 0;
            for (const nbIdx of nbs) {
                avgX += vertices[nbIdx][0];
                avgY += vertices[nbIdx][1];
                avgZ += vertices[nbIdx][2];
            }
            avgX /= nbs.length;
            avgY /= nbs.length;
            avgZ /= nbs.length;

            // Lerp towards average
            newPositions[i][0] += (avgX - vertices[i][0]) * strength;
            newPositions[i][1] += (avgY - vertices[i][1]) * strength;
            newPositions[i][2] += (avgZ - vertices[i][2]) * strength;
        }
        
        // Update main array
        for(let i=0; i<vertices.length; i++) {
            vertices[i] = newPositions[i];
        }
    }
}

// Apply effects
// Jitter amount: Default 0.6
if (CONFIG.jitter > 0) jitterVertices(CONFIG.jitter);

// Smooth: Default 5 iterations, 0.6 strength
// DISABLE SMOOTHING FOR SOUP MODE: It shrinks isolated tets to nothingness.
if (CONFIG.smoothIters > 0 && CONFIG.mode !== 'soup') {
    smoothMesh(CONFIG.smoothIters, CONFIG.smoothStr);
}


// --- Output Writer ---
const stream = fs.createWriteStream(CONFIG.outputFile);
stream.once('open', () => {
    // Write Vertices
    // Format: v x y z
    // Scale vertices to be centered at 0 and roughly unit size?
    // The C++ code scales it automatically, so raw integer grid coords are fine.
    // But centering them helps debugging. Let's keep them as integers for precision.
    
    for (const v of vertices) {
        stream.write(`v ${v[0]} ${v[1]} ${v[2]}\n`);
    }

    // Write Indices
    // Format: t i0 i1 i2 i3
    for (const t of indices) {
        stream.write(`t ${t[0]} ${t[1]} ${t[2]} ${t[3]}\n`);
    }

    stream.end();
    console.log("Done.");
});
