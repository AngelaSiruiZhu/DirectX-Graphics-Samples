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

struct ProxyVertex
{
    float4 Position : SV_Position;
    float2 Depths   : TEXCOORD0;
};

struct PSOutput
{
    float4 Interval : SV_Target0; // front, back, length, tau
    float  Optical  : SV_Target1; // accumulated tau for blending
};

PSOutput main(ProxyVertex input)
{
    PSOutput o;

    float2 clipXY = input.Position.xy; // already in clip space
    float4 clipFront = float4(clipXY, input.Depths.x, 1.0f);
    float4 clipBack  = float4(clipXY, input.Depths.y, 1.0f);

    float4 worldFront = mul(clipFront, Globals.InvViewProj);
    float4 worldBack  = mul(clipBack,  Globals.InvViewProj);
    worldFront /= worldFront.w;
    worldBack  /= worldBack.w;

    float intervalLength = length(worldBack.xyz - worldFront.xyz);
    float tau = intervalLength * Globals.Density;

    float frontDepth = length(worldFront.xyz);
    float backDepth  = length(worldBack.xyz);

    o.Interval = float4(frontDepth, backDepth, intervalLength, tau);
    o.Optical = tau;
    return o;
}
