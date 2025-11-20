//*********************************************************
// Interval Shading Mesh Shader (DirectX 12 port of reference Vulkan shader)
// Generates proxy triangles carrying front/back depth intervals per tet.
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
    float3 Padding;
};

cbuffer SceneConstants : register(b0)
{
    Constants Globals;
};

StructuredBuffer<float4> Vertices : register(t0);
StructuredBuffer<uint>   TetIndices : register(t1);

struct Tet
{
    float4 pos[4];
};

struct Prism
{
    float4 pos[6];
};

struct ClippedTets
{
    Tet tets[3];
    int count;
};

struct Proxy
{
    float4 pos[5];
    int pointCount;
};

struct ProxyVertex
{
    float4 Position : SV_Position;
    float2 Depths   : TEXCOORD0;
};

static const int2 edges[6] = {
    int2(0, 1),
    int2(0, 2),
    int2(0, 3),
    int2(1, 2),
    int2(1, 3),
    int2(2, 3)
};

static const uint3 faces[4] = {
    uint3(0, 1, 2),
    uint3(0, 1, 3),
    uint3(0, 2, 3),
    uint3(1, 2, 3)
};

static const int2 potentialProjection[4] = {
    int2(0, 3),
    int2(1, 2),
    int2(2, 1),
    int2(3, 0)
};

static const int2 potentialCrossing[3] = {
    int2(0, 5),
    int2(1, 4),
    int2(2, 3)
};

float Cross2D(float2 a, float2 b)
{
    return a.x * b.y - a.y * b.x;
}

ClippedTets ClipTet(Tet tet, float nearPlane)
{
    bool clip[4];
    uint clipCount = 0;
    for (uint i = 0; i < 4; ++i)
    {
        clip[i] = tet.pos[i].z < nearPlane;
        clipCount += clip[i] ? 1 : 0;
    }

    ClippedTets result;
    result.count = 0;

    if (clipCount == 0)
    {
        result.count = 1;
        result.tets[0] = tet;
        return result;
    }
    if (clipCount == 4)
    {
        return result;
    }

    bool edgeClip[6] = { false, false, false, false, false, false };
    float4 clipPoint[6];
    float4 otherPoint[6];
    for (int i = 0; i < 6; ++i)
    {
        int i0 = edges[i].x;
        int i1 = edges[i].y;
        edgeClip[i] = (clip[i0] && !clip[i1]) || (!clip[i0] && clip[i1]);
        if (edgeClip[i])
        {
            float4 a = clip[i0] ? tet.pos[i0] : tet.pos[i1];
            float4 b = clip[i0] ? tet.pos[i1] : tet.pos[i0];
            float t = (nearPlane - a.z) / (b.z - a.z);
            clipPoint[i] = a + (b - a) * t;
            otherPoint[i] = b;
        }
    }

    if (clipCount == 1)
    {
        // One clipped vertex -> triangular prism -> 3 tets
        result.count = 3;
        Prism p;
        int count = 0;
        for (int i = 0; i < 6; ++i)
        {
            if (edgeClip[i])
            {
                p.pos[count] = clipPoint[i];
                p.pos[count + 3] = otherPoint[i];
                count++;
            }
        }

        result.tets[0].pos[0] = p.pos[0];
        result.tets[0].pos[1] = p.pos[1];
        result.tets[0].pos[2] = p.pos[2];
        result.tets[0].pos[3] = p.pos[3];

        result.tets[1].pos[0] = p.pos[1];
        result.tets[1].pos[1] = p.pos[2];
        result.tets[1].pos[2] = p.pos[3];
        result.tets[1].pos[3] = p.pos[5];

        result.tets[2].pos[0] = p.pos[1];
        result.tets[2].pos[1] = p.pos[3];
        result.tets[2].pos[2] = p.pos[4];
        result.tets[2].pos[3] = p.pos[5];
    }
    else if (clipCount == 2)
    {
        result.count = 3;
        Prism p;
        int noclip[2];
        int clipIdx[2];
        int countNoClip = 0, countClip = 0;
        for (int i = 0; i < 4; ++i)
        {
            if (!clip[i])
            {
                p.pos[countNoClip * 3] = tet.pos[i];
                noclip[countNoClip++] = i;
            }
            else
            {
                clipIdx[countClip++] = i;
            }
        }
        if (clipIdx[1] < clipIdx[0])
        {
            int tmp = clipIdx[0];
            clipIdx[0] = clipIdx[1];
            clipIdx[1] = tmp;
        }

        for (int i = 0; i < 6; ++i)
        {
            if (edgeClip[i])
            {
                bool eNoClip1 = edges[i].x == noclip[1] || edges[i].y == noclip[1];
                bool eClip1 = edges[i].x == clipIdx[1] || edges[i].y == clipIdx[1];
                int index = (int(eNoClip1) * 3) + (int(eClip1)) + 1;
                p.pos[index] = clipPoint[i];
            }
        }

        result.tets[0].pos[0] = p.pos[0];
        result.tets[0].pos[1] = p.pos[1];
        result.tets[0].pos[2] = p.pos[2];
        result.tets[0].pos[3] = p.pos[3];

        result.tets[1].pos[0] = p.pos[1];
        result.tets[1].pos[1] = p.pos[2];
        result.tets[1].pos[2] = p.pos[3];
        result.tets[1].pos[3] = p.pos[5];

        result.tets[2].pos[0] = p.pos[1];
        result.tets[2].pos[1] = p.pos[3];
        result.tets[2].pos[2] = p.pos[4];
        result.tets[2].pos[3] = p.pos[5];
    }
    else if (clipCount == 3)
    {
        result.count = 1;
        int count = 0;
        for (int i = 0; i < 6; ++i)
        {
            if (edgeClip[i])
            {
                result.tets[0].pos[count++] = clipPoint[i];
            }
        }
        for (int i = 0; i < 4; ++i)
        {
            if (!clip[i])
            {
                result.tets[0].pos[count] = tet.pos[i];
            }
        }
    }

    return result;
}

bool LineIntersection(float2 L1A, float2 L1B, float2 L2A, float2 L2B, out float2 p, out float2 ts)
{
    float2 v1 = L1B - L1A;
    float2 v2 = L2B - L2A;
    float d = Cross2D(v1, v2);
    float2 delta = L1A - L2A;
    float s = Cross2D(v1, delta) / d;
    float t = Cross2D(v2, delta) / d;

    if (s >= 0.0 && s <= 1.0 && t >= 0.0 && t <= 1.0)
    {
        p = float2(L1A.x + (t * v1.x), L1A.y + (t * v1.y));
        ts = float2(t, s);
        return true;
    }
    return false;
}

[NumThreads(1, 1, 1)]
[OutputTopology("triangle")]
void main(
    uint3 gid : SV_GroupID,
    out indices uint3 tris[80],
    out vertices ProxyVertex verts[80]
)
{
    uint tetIndex = gid.x;
    Tet tet = (Tet)0;
    ClippedTets clipped = (ClippedTets)0;
    Proxy proxies[3];
    [unroll] for (int i = 0; i < 3; ++i) proxies[i].pointCount = 0;

    uint vertexCounter = 0;
    uint triCounter = 0;

    if (tetIndex < Globals.TetCount)
    {
        for (uint i = 0; i < 4; ++i)
        {
            uint idx = TetIndices[tetIndex * 4 + i];
            tet.pos[i] = mul(Vertices[idx], Globals.Model);
            tet.pos[i] = mul(tet.pos[i], Globals.View);
        }

        float bias = Globals.NearPlane * 0.1f;
        clipped = ClipTet(tet, Globals.NearPlane + bias);

        for (int i = 0; i < clipped.count; ++i)
        {
            for (int j = 0; j < 4; ++j)
            {
                clipped.tets[i].pos[j] = mul(clipped.tets[i].pos[j], Globals.Proj);
                clipped.tets[i].pos[j] /= clipped.tets[i].pos[j].w;
            }

            int nbTri = 0;
            for (int j = 0; j < 4; ++j)
            {
                float4 p = clipped.tets[i].pos[potentialProjection[j].x];

                uint faceID = potentialProjection[j].y;
                float4 a = clipped.tets[i].pos[faces[faceID].x];
                float4 b = clipped.tets[i].pos[faces[faceID].y];
                float4 c = clipped.tets[i].pos[faces[faceID].z];

                float2 v0 = b.xy - a.xy;
                float2 v1 = c.xy - b.xy;
                float2 v2 = a.xy - c.xy;

                float s0 = Cross2D(p.xy - a.xy, v0);
                float s1 = Cross2D(p.xy - b.xy, v1);
                float s2 = Cross2D(p.xy - c.xy, v2);

                bool inside = (s0 >= 0 && s1 >= 0 && s2 >= 0) || (s0 <= 0 && s1 <= 0 && s2 <= 0);
                if (inside)
                {
                    float s = s0 + s1 + s2;
                    float l0 = s1 / s;
                    float l1 = s2 / s;
                    float l2 = s0 / s;
                    float zInterp = (l0 * a.z + l1 * b.z + l2 * c.z);

                    nbTri = 3;
                    proxies[i].pos[0] = float4(a.xy, a.z, a.z);
                    proxies[i].pos[1] = float4(b.xy, b.z, b.z);
                    proxies[i].pos[2] = float4(c.xy, c.z, c.z);
                    proxies[i].pos[3] = (p.z < zInterp) ? float4(p.xyz, zInterp) : float4(p.xy, zInterp, p.z);
                    proxies[i].pointCount = 4;
                }
            }

            if (nbTri != 0)
                continue;

            for (int j = 0; j < 3; ++j)
            {
                float4 l0a = clipped.tets[i].pos[edges[potentialCrossing[j].x].x];
                float4 l0b = clipped.tets[i].pos[edges[potentialCrossing[j].x].y];
                float4 l1a = clipped.tets[i].pos[edges[potentialCrossing[j].y].x];
                float4 l1b = clipped.tets[i].pos[edges[potentialCrossing[j].y].y];

                float2 p;
                float2 tVals;
                if (LineIntersection(l0a.xy, l0b.xy, l1a.xy, l1b.xy, p, tVals))
                {
                    float z0 = lerp(l0a.z, l0b.z, tVals.x);
                    float z1 = lerp(l1a.z, l1b.z, tVals.y);

                    proxies[i].pos[0] = float4(l0a.xy, l0a.z, l0a.z);
                    proxies[i].pos[1] = float4(l1a.xy, l1a.z, l1a.z);
                    proxies[i].pos[2] = float4(l0b.xy, l0b.z, l0b.z);
                    proxies[i].pos[3] = float4(l1b.xy, l1b.z, l1b.z);
                    proxies[i].pos[4] = (z0 < z1) ? float4(p.xy, z0, z1) : float4(p.xy, z1, z0);
                    proxies[i].pointCount = 5;
                    nbTri = 4;
                }
            }
        }

        for (int i = 0; i < clipped.count; ++i)
        {
            vertexCounter += proxies[i].pointCount;
            triCounter += (proxies[i].pointCount == 4) ? 3 : (proxies[i].pointCount == 5 ? 4 : 0);
        }
    }

    SetMeshOutputCounts(vertexCounter, triCounter);
    if (vertexCounter == 0 || triCounter == 0 || tetIndex >= Globals.TetCount)
        return;

    uint vOffset = 0;
    uint tOffset = 0;
    for (int i = 0; i < clipped.count; ++i)
    {
        for (int j = 0; j < proxies[i].pointCount; ++j)
        {
            verts[vOffset + j].Position = float4(proxies[i].pos[j].xy, 0.0f, 1.0f);
            verts[vOffset + j].Depths = proxies[i].pos[j].zw;
        }

        if (proxies[i].pointCount == 4)
        {
            tris[tOffset++] = uint3(0, 1, 3) + vOffset;
            tris[tOffset++] = uint3(1, 2, 3) + vOffset;
            tris[tOffset++] = uint3(2, 0, 3) + vOffset;
        }
        else if (proxies[i].pointCount == 5)
        {
            tris[tOffset++] = uint3(0, 1, 4) + vOffset;
            tris[tOffset++] = uint3(1, 2, 4) + vOffset;
            tris[tOffset++] = uint3(2, 3, 4) + vOffset;
            tris[tOffset++] = uint3(3, 0, 4) + vOffset;
        }
        vOffset += proxies[i].pointCount;
    }
}
