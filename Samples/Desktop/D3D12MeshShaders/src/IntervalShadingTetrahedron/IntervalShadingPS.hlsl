//*********************************************************
// Interval Shading Pixel Shader
// Reconstructs front/back depth interval and accumulates optical depth.
//*********************************************************

struct Constants
{
    float4x4 Model;
    float4x4 View;
    float4x4 Proj;
    float4x4 ViewProj;
    float4x4 InvViewProj;
    float3 CameraPos; // Replaced padding
    float NearPlane;
    float Density;
    uint DebugMode;
    uint TetCount;
    uint RandomizeOrder;
};

cbuffer SceneConstants : register(b0)
{
    Constants Globals;
};

struct ProxyVertex
{
    float4 Position : SV_Position;
    float4 Depths : TEXCOORD0; // frontZ, frontW, backZ, backW
    float2 NDC : TEXCOORD1;
};

struct PSOutput
{
    float Front : SV_Target0; // min blend
    float Back : SV_Target1; // max blend
    float Optical : SV_Target2; // additive tau
};

PSOutput main(ProxyVertex input)
{
    PSOutput o;

    float frontW = input.Depths.y;
    float backW = input.Depths.w;
    // Use explicit NDC passed from Mesh Shader, as SV_Position is in Screen Space (Pixels)
    float2 clipXYFront = input.NDC * frontW;
    float2 clipXYBack = input.NDC * backW;
    float4 clipFront = float4(clipXYFront, input.Depths.x, frontW);
    float4 clipBack = float4(clipXYBack, input.Depths.z, backW);

    float4 worldFront = mul(clipFront, Globals.InvViewProj);
    float4 worldBack = mul(clipBack, Globals.InvViewProj);
    worldFront /= worldFront.w;
    worldBack /= worldBack.w;

    float intervalLength = length(worldBack.xyz - worldFront.xyz);
    float tau = intervalLength * Globals.Density;

    float frontDepth = length(worldFront.xyz - Globals.CameraPos);
    float backDepth = length(worldBack.xyz - Globals.CameraPos);

    o.Front = frontDepth;
    o.Back = backDepth;
    o.Optical = tau;
    return o;
}