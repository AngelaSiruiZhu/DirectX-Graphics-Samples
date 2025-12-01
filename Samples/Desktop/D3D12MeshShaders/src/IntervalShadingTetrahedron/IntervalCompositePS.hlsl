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
    float3 CameraPos;
    float Time;
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

float hash(float3 p) {
    p = frac(p * 0.3183099 + .1);
    p *= 17.0;
    return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(float3 x) {
    float3 i = floor(x);
    float3 f = frac(x);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(lerp(hash(i + float3(0,0,0)), hash(i + float3(1,0,0)), f.x),
                     lerp(hash(i + float3(0,1,0)), hash(i + float3(1,1,0)), f.x), f.y),
                lerp(lerp(hash(i + float3(0,0,1)), hash(i + float3(1,0,1)), f.x),
                     lerp(hash(i + float3(0,1,1)), hash(i + float3(1,1,1)), f.x), f.y), f.z);
}

float fbm(float3 p) {
    float f = 0.0;
    float w = 0.5;
    for (int i = 0; i < 6; i++) { // Added octave
        f += w * noise(p);
        p *= 2.0;
        w *= 0.5;
    }
    return f;
}

float GetDensity(float3 p) {
    // Increased base frequency from 1.5 to 3.0 for finer detail
    float d = fbm(p * 3.0 + float3(0, 0, Globals.Time * 0.1));
    float corrosion = noise(p * 4.0 - float3(0, Globals.Time * 0.2, 0));
    d -= corrosion * 0.4;
    return saturate(d - 0.1);
}

float GetLight(float3 p, float3 lightDir) {
    float lightDensity = 0.0;
    float step = 0.2;
    for(int i=0; i<4; i++) {
        p += lightDir * step;
        lightDensity += GetDensity(p);
    }
    float transmission = exp(-lightDensity * 1.5);
    return transmission * (1.0 - exp(-lightDensity * 4.0)) * 2.0;
}

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
    case 5: // Volumetric Cloud
    {
        if (front >= back) {
             color = float3(0.5, 0.7, 1.0); // Sky background
             break;
        }

        // Reconstruct ray direction
        float2 ndc = uv * 2.0 - 1.0;
        ndc.y = -ndc.y;
        float4 clipFar = float4(ndc, 1.0, 1.0);
        float4 worldFar = mul(clipFar, Globals.InvViewProj);
        worldFar /= worldFar.w;
        
        float3 rayDir = normalize(worldFar.xyz - Globals.CameraPos);
        
        float dist = front;
        float stepSize = 0.02; // Finer steps for detail (was 0.05)
        
        float totalTransmittance = 1.0;
        float3 totalLightEnergy = 0.0;
        
        // float3 sunColor = float3(1.0, 0.9, 0.7) * 1.5;
        // float3 ambientColor = float3(0.6, 0.7, 0.9) * 0.3;
        // float3 lightDir = float3(0.0, 1.0, 0.0);

        for (int i = 0; i < 128; i++) { // More steps (was 64)
            if (dist >= back || totalTransmittance < 0.01) break;

            float3 p = Globals.CameraPos + rayDir * dist;
            
            // FLUFFY CLOUD DENSITY:
            float noiseDensity = GetDensity(p * (Globals.Density)); 
            
            // SOFT EDGE FADE:
            float softness = 0.5; 
            float edgeFade = saturate((dist - front) / softness) * saturate((back - dist) / softness);
            
            // Apply noise + fade
            // LOWER DENSITY: Multiplier 0.7 -> 0.4 for more transparency/depth
            // LOWER BIAS: 0.05 -> 0.0 to allow pure holes
            float density = saturate(noiseDensity * 2.0) * edgeFade; 

            if (density > 0.0001) { // Catch faint wisps
                // Beer's Law
                // float lightTransmittance = GetLight(p, lightDir); 
                // float3 light = sunColor * lightTransmittance + ambientColor;
                float3 light = 0.0f;
                float stepTransmittance = exp(-density * stepSize * 1.0);
                float3 absorbedLight = light * (1.0 - stepTransmittance) * totalTransmittance;
                
                totalLightEnergy += absorbedLight;
                totalTransmittance *= stepTransmittance;
            }
            dist += stepSize;
        }
        
        float3 skyColor = float3(0.5, 0.7, 1.0);
        color = totalLightEnergy + skyColor * totalTransmittance;
        alpha = 1.0f;
        break;
    }
    default:
        color = DepthToGray(front);
        break;
    }

    return float4(color, alpha);
}
