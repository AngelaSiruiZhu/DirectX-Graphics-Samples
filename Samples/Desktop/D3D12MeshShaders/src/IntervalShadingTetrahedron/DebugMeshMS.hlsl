//*********************************************************
// Debug Mesh Shader
// Renders wireframe tetrahedrons
//*********************************************************

struct Constants
{
    float4x4 Model;
    float4x4 View;
    float4x4 Proj;
    float4x4 ViewProj;
    float4x4 InvViewProj;
    float NearPlane;
    float Density;
    uint DebugMode;
    uint TetCount;
    uint RandomizeOrder;
    float3 CameraPos;
    float Time;
};

cbuffer SceneConstants : register(b0)
{
    Constants Globals;
};

StructuredBuffer<float4> Vertices : register(t0);
StructuredBuffer<uint>   TetIndices : register(t1);

struct VertexOut
{
    float4 Position : SV_Position;
    float4 Color    : COLOR0;
};

[NumThreads(32, 1, 1)]
[OutputTopology("line")]
void main(
    uint3 gid : SV_GroupID,
    uint3 gtid : SV_GroupThreadID,
    out indices uint2 lines[192], // 32 * 6
    out vertices VertexOut verts[128] // 32 * 4
)
{
    uint tetIndex = gid.x * 32 + gtid.x;
    bool visible = tetIndex < Globals.TetCount;

    // Calculate compact offsets
    uint count = WaveActiveCountBits(visible);
    uint vBase = WavePrefixCountBits(visible) * 4;
    uint lBase = WavePrefixCountBits(visible) * 6;

    SetMeshOutputCounts(count * 4, count * 6);

    if (visible)
    {
        // Load vertices
        for (uint i = 0; i < 4; ++i)
        {
            uint idx = TetIndices[tetIndex * 4 + i];
            float4 pos = Vertices[idx];
            
            // Transform to clip space
            pos = mul(pos, Globals.Model);
            pos = mul(pos, Globals.ViewProj);
            
            verts[vBase + i].Position = pos;
            
            // Color based on Tet Index (hash) or just white
            // float3 c = float3(
            //     (tetIndex * 0.31) % 1.0,
            //     (tetIndex * 0.53) % 1.0, 
            //     (tetIndex * 0.79) % 1.0
            // );
            verts[vBase + i].Color = float4(1.0, 1.0, 1.0, 0.2); // White, semi-transparent
        }

        // Emit lines (indices relative to the vertex output array)
        lines[lBase + 0] = uint2(vBase + 0, vBase + 1);
        lines[lBase + 1] = uint2(vBase + 0, vBase + 2);
        lines[lBase + 2] = uint2(vBase + 0, vBase + 3);
        lines[lBase + 3] = uint2(vBase + 1, vBase + 2);
        lines[lBase + 4] = uint2(vBase + 1, vBase + 3);
        lines[lBase + 5] = uint2(vBase + 2, vBase + 3);
    }
}
