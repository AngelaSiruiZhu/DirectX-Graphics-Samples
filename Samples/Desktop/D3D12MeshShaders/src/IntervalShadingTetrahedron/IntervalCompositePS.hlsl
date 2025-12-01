//*********************************************************
// Fullscreen composite for Interval Shading
// Implements: Ratio Tracking (Transmittance) & Single Scattering
//*********************************************************

struct Constants
{
    float4x4 Model;
    float4x4 View;
    float4x4 Proj;
    float4x4 ViewProj;
    float4x4 InvViewProj;

    float3 CameraPos;
    float NearPlane;

    float3 LightDir;
    float Density;

    float3 LightColor;
    uint DebugMode;

    float3 SigmaS;      // Scattering coefficient color
    uint TetCount;

    float G;            // Phase anisotropy
    uint RandomizeOrder;
    float2 Padding;
};

cbuffer SceneConstants : register(b0)
{
    Constants Globals;
};

Texture2D<float>  FrontTex   : register(t2);
Texture2D<float>  BackTex    : register(t3);
Texture2D<float>  OpticalTex : register(t4);
SamplerState LinearClamp : register(s0);

struct PSIn
{
    float4 Position : SV_Position;
    float2 Tex : TEXCOORD0;
};

//-----------------------------------------------------------------------------
// Helpers
//-----------------------------------------------------------------------------

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

//-----------------------------------------------------------------------------
// Utils
//-----------------------------------------------------------------------------

float PhaseHG(float g, float cosTheta)
{
    float g2 = g * g;
    return (1.0f - g2) / (4.0f * 3.14159265f * pow(1.0f + g2 - 2.0f * g * cosTheta, 1.5f));
}

float PhaseCloud(float g, float cosTheta)
{
    // Cloud phase function: Strong forward peak (silver lining) + broader backscatter
    float forward = PhaseHG(g, cosTheta);
    float backward = PhaseHG(-0.3f, cosTheta);
    float mixFactor = 0.7f;
    return lerp(backward, forward, mixFactor);
}

uint pcg_hash(uint seed)
{
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float rand(inout uint rngState)
{
    rngState = pcg_hash(rngState);
    return float(rngState) / 4294967296.0f;
}

// 3D Value Noise
float hash(float3 p)
{
    p = frac(p * 0.3183099 + .1);
    p *= 17.0;
    return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(in float3 x)
{
    float3 i = floor(x);
    float3 f = frac(x);
    f = f * f * (3.0 - 2.0 * f);

    return lerp(lerp(lerp(hash(i + float3(0, 0, 0)),
        hash(i + float3(1, 0, 0)), f.x),
        lerp(hash(i + float3(0, 1, 0)),
            hash(i + float3(1, 1, 0)), f.x), f.y),
        lerp(lerp(hash(i + float3(0, 0, 1)),
            hash(i + float3(1, 0, 1)), f.x),
            lerp(hash(i + float3(0, 1, 1)),
                hash(i + float3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(float3 p)
{
    float f = 0.0;
    float scale = 0.5;
    // Mid-frequency for balanced detail
    p *= 0.9;
    for (int i = 0; i < 4; i++) {
        f += scale * noise(p);
        p *= 2.05;
        scale *= 0.5;
    }
    return f;
}

// Procedural Density
float GetDensity(float3 p)
{
    float cloudNoise = fbm(p + float3(0.0, 2.0, 0.0));

    // Remap noise to create more distinct "clumps" and empty spaces
    // Values below 0.35 are cut to 0 (empty space inside the bunny)
    // Values above 0.35 ramp up quickly.
    float density = smoothstep(0.35f, 0.8f, cloudNoise);

    // Multiply by base density
    return Globals.Density * density;
}

//-----------------------------------------------------------------------------
// Integrators
//-----------------------------------------------------------------------------

// Returns Transmittance (0..1) along ray
float RatioTrackingTransmittance(float3 ro, float3 rd, float t0, float t1, inout uint rngState)
{
    float transmittance = 1.0f;
    float t = t0;
    float majorant = Globals.Density * 1.0f;

    const int MAX_STEPS = 24;

    for (int i = 0; i < MAX_STEPS; ++i)
    {
        float dt = -log(1.0f - rand(rngState)) / majorant;
        t += dt;
        if (t >= t1) break;

        float3 pos = ro + rd * t;
        float density = GetDensity(pos);

        // Null Probability = 1 - (Extinction / Majorant)
        float probNull = 1.0f - saturate(density / majorant);
        transmittance *= probNull;

        // Optimization: Early out if dark enough
        if (transmittance < 0.02f) return 0.0f;
    }
    return transmittance;
}

float3 IntegrateScattering(float3 ro, float3 rd, float t0, float t1, uint seed)
{
    uint rngState = seed;
    float3 totalRadiance = 0.0f;
    float3 throughput = 1.0f;

    float t = t0;
    float majorant = Globals.Density * 1.0f;

    float cosTheta = dot(rd, Globals.LightDir);
    float phase = PhaseCloud(Globals.G, cosTheta);

    // Ambient Light (Skylight from top)
    // Adds blue-ish tint to shadows
    float3 ambientColor = float3(0.05f, 0.1f, 0.2f) * 0.5f;

    // Albedo: 0.9 means 10% absorption per interaction. 
    // This is CRITICAL for volumetric depth appearance.
    float3 cloudAlbedo = Globals.SigmaS * 0.9f;

    const int MAX_STEPS = 128; // High steps for quality

    for (int i = 0; i < MAX_STEPS; ++i)
    {
        // Delta Tracking Step
        float dt = -log(1.0f - rand(rngState)) / majorant;
        t += dt;
        if (t >= t1) break;

        float3 pos = ro + rd * t;

        // Soft edges near mesh boundaries
        float distToEdge = min(t - t0, t1 - t);
        float depthFade = smoothstep(0.0f, 0.05f, distToEdge);

        float density = GetDensity(pos);
        density *= depthFade;

        // 1. Calculate In-Scattering (Sun light reaching this point)
        uint shadowRng = pcg_hash(rngState + uint(t * 157.0f));
        float sunTransmittance = RatioTrackingTransmittance(pos, Globals.LightDir, 0.02f, 3.0f, shadowRng);

        float3 incomingLight = (Globals.LightColor * sunTransmittance * phase) + (ambientColor * density);

        // 2. Add to Radiance
        // Contribution = Throughput * (Scattering / Majorant) * Incoming
        // Scattering = Density * CloudAlbedo
        float3 scattering = density * cloudAlbedo;

        totalRadiance += throughput * (scattering / majorant) * incomingLight;

        // 3. Attenuate Camera Ray (Ratio Tracking)
        // Extinction = Density
        // Null Prob = 1 - (Extinction / Majorant)
        float probNull = 1.0f - saturate(density / majorant);
        throughput *= probNull;

        if (length(throughput) < 0.01f) break;
    }

    return totalRadiance;
}

float4 main(PSIn input) : SV_Target
{
    float front = FrontTex.SampleLevel(LinearClamp, input.Tex, 0);
    float back = BackTex.SampleLevel(LinearClamp, input.Tex, 0);

    // Dark Blue Background
    float3 skyTop = float3(0.02, 0.04, 0.08);
    float3 skyBot = float3(0.0, 0.01, 0.02);
    float3 bgColor = lerp(skyBot, skyTop, input.Tex.y);

    if (front >= back)
    {
        return float4(bgColor, 1.0f);
    }

    float2 ndc = input.Tex * 2.0f - 1.0f;
    ndc.y *= -1.0f;
    float4 nearPos = mul(float4(ndc, 0.0f, 1.0f), Globals.InvViewProj);
    nearPos /= nearPos.w;
    float3 rayDir = normalize(nearPos.xyz - Globals.CameraPos);

    uint seed = uint(input.Position.x) * 1973 + uint(input.Position.y) * 9277 + uint(front * 123.0f);

    float3 color = 0;

    if (Globals.DebugMode == 5)
    {
        float3 volumeLight = IntegrateScattering(Globals.CameraPos, rayDir, front, back, seed);

        // Approximate background occlusion
        float dist = back - front;
        float approxT = exp(-dist * Globals.Density * 0.4f);

        color = volumeLight + bgColor * approxT;
    }
    else if (Globals.DebugMode == 4)
    {
         float tau = (back - front) * Globals.Density * 0.5;
         color = HeatMap(saturate(tau * 0.2));
    }
    else
    {
        color = DepthToGray(front);
    }

    // Filmic Tone Mapping
    color = max(0, color - 0.004);
    color = (color * (6.2 * color + 0.5)) / (color * (6.2 * color + 1.7) + 0.06);

    return float4(color, 1.0f);
}