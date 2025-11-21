//*********************************************************
// Fullscreen composite for Interval Shading debug + Beer-Lambert
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

Texture2D<float>  FrontTex   : register(t2);
Texture2D<float>  BackTex    : register(t3);
Texture2D<float>  OpticalTex : register(t4);
SamplerState LinearClamp      : register(s0);

struct PSIn
{
    float4 Position : SV_Position;
    float2 Tex      : TEXCOORD0;
};

float3 DepthToGray(float d)
{
    float v = saturate(d * 0.05f);
    v = 1.0f - v;
    v = v * 0.9f + 0.1f;
    return float3(v, v, v);
}

float3 HeatMap(float v)
{
    float3 c = saturate(float3(
        1.5f * v,
        1.5f * (1.0f - abs(v - 0.5f) * 2.0f),
        1.5f * (1.0f - v)));
    return c;
}

float4 main(PSIn input) : SV_Target
{
    float2 uv = input.Tex;
    float front = FrontTex.SampleLevel(LinearClamp, uv, 0);
    float back  = BackTex.SampleLevel(LinearClamp, uv, 0);
    float tau   = OpticalTex.SampleLevel(LinearClamp, uv, 0);
    float3 color = 0;
    float alpha = 1.0f;

    switch (Globals.DebugMode)
    {
    case 0: // front depth
        color = DepthToGray(front);
        break;
    case 1: // back depth
        color = DepthToGray(back);
        break;
    case 2: // interval length
        color = HeatMap(saturate((back - front) * 0.2f));
        break;
    case 3: // tau debug
        color = HeatMap(saturate(tau * 0.2f));
        break;
    case 4: // Transmittance
    {
        float T = exp(-tau);
        color = float3(T, T, T);
        break;
    }
    case 5: // Fog/Crystal view
    {
        float T = exp(-tau);
        float3 fogColor = float3(0.7f, 0.9f, 1.0f);
        color = lerp(fogColor, float3(1.0f, 1.0f, 1.05f), T);
        alpha = 1.0f;
        break;
    }
    default:
        color = DepthToGray(front);
        break;
    }

    return float4(color, alpha);
}
