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
    float d = fbm(p * 3.0 + float3(0, 0, Globals.Time * 0.5));
    float corrosion = noise(p * 4.0 - float3(0, Globals.Time * 1.0, 0));
    d -= corrosion * 0.4;
    return saturate((d - 0.05) * 2.0);
}

float GetLight(float3 p, float3 lightDir) {
    float lightDensity = 0.0;
    float step = 0.2;
    for(int i=0; i<6; i++) {
        p += lightDir * step;
        lightDensity += GetDensity(p);
    }
    // Reduced absorption (0.5) and removed the scattering term to allow light to penetrate
    return exp(-lightDensity * 0.5);
}

float GetDensityLowQ(float3 p) {
    // Low quality density for radial blur (2 noise calls)
    float d = noise(p * 3.0 + float3(0, 0, Globals.Time * 0.5));
    float corrosion = noise(p * 4.0 - float3(0, Globals.Time * 1.0, 0));
    d -= corrosion * 0.4;
    return saturate((d - 0.05) * 2.0);
}

float HenyeyGreenstein(float g, float costheta)
{
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * 3.14159 * pow(1.0 + g2 - 2.0 * g * costheta, 1.5));
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

float3 GetWorldPos(float2 uv, float depth)
{
    float2 ndc = uv * 2.0 - 1.0;
    ndc.y = -ndc.y;
    float4 clipFar = float4(ndc, 1.0, 1.0);
    float4 worldFar = mul(clipFar, Globals.InvViewProj);
    worldFar /= worldFar.w;
    float3 rayDir = normalize(worldFar.xyz - Globals.CameraPos);
    return Globals.CameraPos + rayDir * depth;
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
    case 5: // Volumetric Cloud + Light ( + screen space god rays)
    {
        float3 cloudColor = 0;
        float cloudTransmittance = 1.0;
        float3 accumulatedLight = 0;
        
        float3 lightPos = float3(0,0,0);
        float3 lightColor = float3(1.0, 0.9, 0.7) * 0.05; 

        if (front < back) {
            // Reconstruct ray direction
            float2 ndc = uv * 2.0 - 1.0;
            ndc.y = -ndc.y;
            float4 clipFar = float4(ndc, 1.0, 1.0);
            float4 worldFar = mul(clipFar, Globals.InvViewProj);
            worldFar /= worldFar.w;
            
            float3 rayDir = normalize(worldFar.xyz - Globals.CameraPos);
            
            float dist = front;
            float stepSize = 0.02; 
            
            for (int i = 0; i < 64; i++) { 
                if (dist >= back || cloudTransmittance < 0.01) break;

                float3 p = Globals.CameraPos + rayDir * dist;
                float noiseDensity = GetDensity(p * (Globals.Density)); 
                float softness = 0.5; 
                float edgeFade = saturate((dist - front) / softness) * saturate((back - dist) / softness);
                float density = saturate(noiseDensity * 2.0) * edgeFade; 

                if (density > 0.0001) { 
                    float distToLight = length(p);
                    
                    // Shadow march towards light (3 samples)
                    float shadowDensity = 0;
                    float3 s1 = p * 0.75;
                    float3 s2 = p * 0.50;
                    float3 s3 = p * 0.25;
                    shadowDensity += GetDensity(s1 * Globals.Density);
                    shadowDensity += GetDensity(s2 * Globals.Density);
                    shadowDensity += GetDensity(s3 * Globals.Density);
                    
                    float lightTransmittance = exp(-shadowDensity * 1.5); // Absorption along light ray
                    float attenuation = 1.0 / (0.1 + distToLight * distToLight * 0.05); 
                    
                    float3 sunColor = float3(1.0, 0.95, 0.9) * 0.5; //directional light
                    float3 ambient = float3(0.6,0.6,0.6); // ambient
                    
                    float3 incoming = (lightColor * lightTransmittance * attenuation) + sunColor + ambient;
                    
                    float stepTransmittance = exp(-density * stepSize * 1.0);
                    float3 scattered = incoming * density * stepSize;
                    
                    accumulatedLight += scattered * cloudTransmittance;
                    cloudTransmittance *= stepTransmittance;
                }
                dist += stepSize;
            }
        }
        
        float3 skyColor = float3(0.5, 0.7, 1.0);
        float3 finalCloudColor = accumulatedLight + skyColor * cloudTransmittance;

        // Screen Space God Rays using Radial Blur
        float4 lightClip = mul(float4(lightPos, 1.0), Globals.ViewProj); // light source screen position
        float2 lightScreen = lightClip.xy / lightClip.w;
        lightScreen = lightScreen * 0.5 + 0.5;
        lightScreen.y = 1.0 - lightScreen.y;
        
        float2 deltaTexCoord = (uv - lightScreen);
        int samples = 32; 
        float density = 0.9;
        float weight = 0.008;
        float decay = 0.97;
        
        deltaTexCoord *= 1.0 / float(samples) * density;
        
        float2 coord = uv;
        float illuminationDecay = 1.0;
        float3 godRayColor = 0.0;
        
        for(int i=0; i < samples; i++)
        {
            coord -= deltaTexCoord;
            
            float sFront = FrontTex.SampleLevel(LinearClamp, coord, 0);
            float sBack  = BackTex.SampleLevel(LinearClamp, coord, 0);
            
            float sampleTransmittance = 0.0;
            
            if (sFront < sBack) // Inside volume
            {
                // Sample 3 points to catch internal density structure
                float3 rayDir = normalize(GetWorldPos(coord, sBack) - Globals.CameraPos);
                float step = (sBack - sFront) / 3.0;
                float maxDensity = 0;
                
                // Check 3 points along the ray segment inside the box
                // use max() because if ANY part is dense, it blocks the light.
                float3 p1 = Globals.CameraPos + rayDir * (sFront + step * 0.5);
                float3 p2 = Globals.CameraPos + rayDir * (sFront + step * 1.5);
                float3 p3 = Globals.CameraPos + rayDir * (sFront + step * 2.5);
                
                maxDensity = max(maxDensity, GetDensityLowQ(p1 * Globals.Density));
                maxDensity = max(maxDensity, GetDensityLowQ(p2 * Globals.Density));
                maxDensity = max(maxDensity, GetDensityLowQ(p3 * Globals.Density));
                
                // If max density is high -> blocked.
                float block = smoothstep(0.2, 0.6, maxDensity);
                sampleTransmittance = 1.0 - block;
                
                float distToLight = length(p2); // Use middle point distance
                float attenuation = 1.0 / (0.1 + distToLight * distToLight * 0.2);
                sampleTransmittance *= attenuation;
            }
            
            godRayColor += sampleTransmittance * illuminationDecay * weight;
            illuminationDecay *= decay;
        }
        
        color = finalCloudColor + godRayColor * float3(0.4, 0.3, 0.2);
        alpha = 1.0f;
        break;
    }
    default:
        color = DepthToGray(front);
        break;
    }

    return float4(color, alpha);
}
