//*********************************************************
// Interval Shading Mesh Shader - Depth Visualization
// Based on: https://github.com/ThibaultTricard/Interval-Shading
//*********************************************************

#define ROOT_SIG "CBV(b0)"

struct MeshOutput
{
    float4 Position : SV_Position;
    float3 WorldPos : POSITION0;
    float3 RayEntry : POSITION1;  // Where ray enters the volume
    float3 RayExit : POSITION2;   // Where ray exits the volume
    float4 Color : COLOR;
    uint TriangleID : TEXCOORD0;
};

cbuffer SceneConstants : register(b0)
{
    float4x4 WorldViewProj;
    float4x4 World;
    float3 CameraPosition;
    float Time;
    uint ShowDepth;
    float3 _padding;
};

[RootSignature(ROOT_SIG)]
[NumThreads(4, 1, 1)]
[OutputTopology("triangle")]
void main(
    uint gtid : SV_GroupThreadID,
    out vertices MeshOutput verts[4],
    out indices uint3 tris[4]
)
{
    SetMeshOutputCounts(4, 4);

    // Basic tetrahedron vertices (regular tetrahedron)
    const float size = 1.0f;
    float3 positions[4] = {
        float3(0, size, 0),           // Top
        float3(-size, -size, size),   // Bottom front-left
        float3(size, -size, size),    // Bottom front-right  
        float3(0, -size, -size)       // Bottom back
    };

    // Generate vertices with interval information
    if (gtid < 4)
    {
        float3 localPos = positions[gtid];
        float3 worldPos = mul(float4(localPos, 1.0), World).xyz;
        
        verts[gtid].Position = mul(float4(localPos, 1.0), WorldViewProj);
        verts[gtid].WorldPos = worldPos;
        
        // INTERVAL SHADING KEY CONCEPT:
        // For each vertex, compute where a ray from the camera
        // enters (RayEntry) and exits (RayExit) the volume
        
        // Entry point is the vertex itself (front-facing surface)
        verts[gtid].RayEntry = worldPos;
        
        // Exit point: estimate by projecting ray through tetrahedron
        float3 rayDir = normalize(worldPos - CameraPosition);
        // Simple approximation: exit at opposite side of tetrahedron
        float3 exitPos = -localPos * 0.9f;
        verts[gtid].RayExit = mul(float4(exitPos, 1.0), World).xyz;
        
        // Assign colors based on depth
        float depth = length(worldPos - CameraPosition);
        verts[gtid].Color = float4(depth / 5.0f, 0.5f, 1.0f - depth / 5.0f, 0.8f);
        verts[gtid].TriangleID = gtid;
    }

    // Define 4 triangular faces
    if (gtid == 0)
    {
        tris[0] = uint3(0, 2, 1); // Top front
        tris[1] = uint3(0, 3, 2); // Top right
        tris[2] = uint3(0, 1, 3); // Top left
        tris[3] = uint3(1, 2, 3); // Bottom
    }
}
