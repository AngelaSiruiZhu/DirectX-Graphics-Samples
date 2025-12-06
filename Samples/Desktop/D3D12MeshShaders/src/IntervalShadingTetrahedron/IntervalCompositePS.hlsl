//*********************************************************
// Cloud Bunny - Volumetric Rendering Composite Shader
// Implements null-scattering with multiple scattering for cloud appearance
// Based on Miller et al. 2019 path integral formulation
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

    float3 SigmaS;      // Scattering albedo
    uint TetCount;

    float G;            // Phase function anisotropy
    uint RandomizeOrder;
    float2 Padding;
};

cbuffer SceneConstants : register(b0)
{
    Constants Globals;
};

Texture2D<float> FrontTex   : register(t2);
Texture2D<float> BackTex    : register(t3);
Texture2D<float> OpticalTex : register(t4);
SamplerState LinearClamp : register(s0);

struct PSIn
{
    float4 Position : SV_Position;
    float2 Tex : TEXCOORD0;
};

//=============================================================================
// Constants & Config
//=============================================================================
static const float PI = 3.14159265358979323846;
static const int NUM_SAMPLES = 24;       // Samples per pixel
static const int MAX_BOUNCES = 6;        // Multiple scattering bounces
static const int MAX_MARCH_STEPS = 96;   // Steps per bounce
static const int MAX_SHADOW_STEPS = 24;  // Shadow ray steps

//=============================================================================
// Random Number Generator (PCG)
//=============================================================================
uint pcg_hash(uint seed)
{
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float rand(inout uint rng)
{
    rng = pcg_hash(rng);
    return float(rng) / 4294967296.0f;
}

//=============================================================================
// Noise Functions for Cloud Density
//=============================================================================
float hash3D(float3 p)
{
    p = frac(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return frac((p.x + p.y) * p.z);
}

float noise3D(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);  // Smoothstep

    return lerp(
        lerp(lerp(hash3D(i + float3(0, 0, 0)), hash3D(i + float3(1, 0, 0)), f.x),
            lerp(hash3D(i + float3(0, 1, 0)), hash3D(i + float3(1, 1, 0)), f.x), f.y),
        lerp(lerp(hash3D(i + float3(0, 0, 1)), hash3D(i + float3(1, 0, 1)), f.x),
            lerp(hash3D(i + float3(0, 1, 1)), hash3D(i + float3(1, 1, 1)), f.x), f.y),
        f.z);
}

// Fractal Brownian Motion for cloud-like detail
float fbm(float3 p, int octaves)
{
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;

    for (int i = 0; i < octaves; i++)
    {
        value += amplitude * noise3D(p * frequency);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

// Worley noise for puffy cloud billows
// Worley noise for puffy cloud billows
float worley(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);

    float minDist = 1.0;
    for (int x = -1; x <= 1; x++)
    {
        for (int y = -1; y <= 1; y++)
        {
            for (int z = -1; z <= 1; z++)
            {
                float3 neighbor = float3(x, y, z);
                float3 pt = float3(hash3D(i + neighbor + float3(0, 0, 0)),
                    hash3D(i + neighbor + float3(5.2, 1.3, 2.8)),
                    hash3D(i + neighbor + float3(9.4, 2.1, 7.5))) * 0.5 + 0.25;
                float3 diff = neighbor + pt - f;
                minDist = min(minDist, length(diff));
            }
        }
    }
    return minDist;
}

//=============================================================================
// Cloud Density Function
//=============================================================================
float GetCloudDensity(float3 worldPos, float t, float tMin, float tMax)
{
    // Base density from user parameter
    float baseDensity = Globals.Density;

    // Soft falloff at volume boundaries (important for clean edges)
    float edgeDist = min(t - tMin, tMax - t);
    float volumeThickness = tMax - tMin;
    float normalizedEdge = edgeDist / max(volumeThickness * 0.15, 0.01);
    float edgeFade = smoothstep(0.0, 1.0, normalizedEdge);

    // Cloud noise - multiple scales for detail
    float3 noiseCoord = worldPos * 1.8;  // Scale for cloud features

    // Large-scale billowy structure
    float largeNoise = fbm(noiseCoord * 0.5, 3);

    // Medium detail
    float medNoise = fbm(noiseCoord * 1.2 + float3(5.2, 1.3, 2.8), 4);

    // Fine wispy detail  
    float fineNoise = fbm(noiseCoord * 3.0 + float3(9.4, 2.1, 7.5), 3);

    // Worley for puffy billows
    float billows = 1.0 - worley(noiseCoord * 1.5);
    billows = billows * billows;  // Sharpen

    // Combine noises
    float cloudShape = largeNoise * 0.6 + medNoise * 0.3 + fineNoise * 0.1;
    cloudShape = cloudShape * 0.7 + billows * 0.3;

    // Remap to create cloud-like density distribution
    // This creates denser cores and wispy edges
    float density = smoothstep(0.3, 0.7, cloudShape);
    density = pow(density, 0.8);  // Boost mid-tones

    // Apply edge fade and base density
    density *= edgeFade * baseDensity;

    return density;
}

//=============================================================================
// Phase Functions
//=============================================================================

// Henyey-Greenstein phase function
float PhaseHG(float cosTheta, float g)
{
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * cosTheta;
    return (1.0 - g2) / (4.0 * PI * pow(max(denom, 0.0001), 1.5));
}

// Two-lobe phase function for clouds (forward peak + backscatter)
float PhaseCloud(float cosTheta, float g)
{
    // Strong forward scattering (silver lining effect)
    float forward = PhaseHG(cosTheta, g);
    // Weak backscatter for fill light
    float back = PhaseHG(cosTheta, -0.2);
    // Blend: mostly forward, some back
    return lerp(back, forward, 0.85);
}

// Sample direction from HG phase function
float3 SamplePhaseHG(float3 wo, float g, inout uint rng)
{
    float xi1 = rand(rng);
    float xi2 = rand(rng);

    float cosTheta;
    if (abs(g) < 0.001)
    {
        // Isotropic
        cosTheta = 1.0 - 2.0 * xi1;
    }
    else
    {
        float sqTerm = (1.0 - g * g) / (1.0 - g + 2.0 * g * xi1);
        cosTheta = (1.0 + g * g - sqTerm * sqTerm) / (2.0 * g);
    }
    cosTheta = clamp(cosTheta, -1.0, 1.0);

    float sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));
    float phi = 2.0 * PI * xi2;

    // Build orthonormal basis
    float3 w = normalize(wo);
    float3 u = abs(w.y) < 0.999 ? normalize(cross(float3(0, 1, 0), w)) : normalize(cross(float3(1, 0, 0), w));
    float3 v = cross(w, u);

    return normalize(u * (cos(phi) * sinTheta) + v * (sin(phi) * sinTheta) + w * cosTheta);
}

//=============================================================================
// Transmittance Estimation (Ratio Tracking)
//=============================================================================
float EstimateTransmittance(float3 ro, float3 rd, float tMin, float tMax, float majorant, inout uint rng)
{
    if (majorant < 0.0001) return 1.0;

    float transmittance = 1.0;
    float t = tMin;

    for (int i = 0; i < MAX_SHADOW_STEPS; i++)
    {
        // Sample free-flight distance
        float xi = rand(rng);
        float dt = -log(max(1e-6, 1.0 - xi)) / majorant;
        t += dt;

        if (t >= tMax) break;

        float3 pos = ro + rd * t;
        float density = GetCloudDensity(pos, t, tMin, tMax);

        // Null-collision probability
        float pNull = 1.0 - saturate(density / majorant);
        transmittance *= pNull;

        if (transmittance < 0.005) return 0.0;
    }

    return transmittance;
}

//=============================================================================
// Main Volume Integrator - Delta Tracking with Multiple Scattering
//=============================================================================
float3 IntegrateCloud(float3 rayOrigin, float3 rayDir, float tMin, float tMax, inout uint rng)
{
    // Majorant (upper bound on density)
    float majorant = Globals.Density * 1.2;
    if (majorant < 0.0001) return float3(0, 0, 0);

    // Scattering albedo - high for clouds
    float3 albedo = saturate(Globals.SigmaS);

    // Accumulated radiance and throughput
    float3 L = float3(0, 0, 0);
    float3 throughput = float3(1, 1, 1);

    // Current ray state
    float3 ro = rayOrigin;
    float3 rd = rayDir;
    float t0 = tMin;
    float t1 = tMax;
    float t = t0;

    // Sky/ambient light (soft blue for outdoor feel)
    float3 skyColor = float3(0.4, 0.5, 0.7);
    float3 groundColor = float3(0.15, 0.12, 0.1);

    for (int bounce = 0; bounce < MAX_BOUNCES; bounce++)
    {
        bool hitScatter = false;

        for (int step = 0; step < MAX_MARCH_STEPS; step++)
        {
            // Sample free-flight distance from exponential distribution
            float xi = rand(rng);
            float dt = -log(max(1e-6, 1.0 - xi)) / majorant;
            t += dt;

            if (t >= t1) break;  // Exited volume

            float3 pos = ro + rd * t;
            float density = GetCloudDensity(pos, t, t0, t1);

            // Real collision probability
            float pReal = saturate(density / majorant);

            if (rand(rng) < pReal)
            {
                // === REAL SCATTERING EVENT ===

                // ----- Next Event Estimation (Direct Light) -----
                float shadowDist = 3.0;  // How far to trace shadow
                uint shadowRng = pcg_hash(rng + uint(t * 1000.0));
                float Tr = EstimateTransmittance(pos, Globals.LightDir, 0.01, shadowDist, majorant, shadowRng);

                // Phase function
                float cosTheta = dot(-rd, Globals.LightDir);
                float phase = PhaseCloud(cosTheta, Globals.G);

                // Direct light contribution
                float3 directLight = Globals.LightColor * Tr * phase;

                // ----- Ambient/Sky Light -----
                // Sample ambient from above (approximation)
                float3 up = float3(0, 1, 0);
                float ambientPhase = PhaseCloud(dot(-rd, up), Globals.G);
                float3 ambientLight = skyColor * 0.3 * ambientPhase;

                // Ground bounce (very subtle)
                float3 down = float3(0, -1, 0);
                float groundPhase = PhaseCloud(dot(-rd, down), Globals.G);
                ambientLight += groundColor * 0.1 * groundPhase;

                // ----- Accumulate Radiance -----
                float3 sigmaS = density * albedo;
                L += throughput * sigmaS * (directLight + ambientLight);

                // ----- Update Throughput -----
                throughput *= albedo;

                // Russian roulette for path termination
                float pContinue = min(0.95, max(throughput.r, max(throughput.g, throughput.b)));
                if (bounce > 2 && rand(rng) > pContinue)
                    return L;
                throughput /= max(pContinue, 0.01);

                // ----- Sample New Direction -----
                rd = SamplePhaseHG(rd, Globals.G, rng);

                // Update ray for next segment
                ro = pos;
                t0 = 0.0;
                t1 = t1 - t + 0.5;  // Approximate remaining distance + some extra
                t = t0;

                hitScatter = true;
                break;
            }
            // else: NULL COLLISION - continue marching
        }

        if (!hitScatter) break;  // Exited volume without scattering
    }

    return L;
}

//=============================================================================
// Debug Visualizations
//=============================================================================
float3 DepthVis(float d)
{
    float v = 1.0 - saturate(d * 0.1);
    return float3(v, v, v);
}

float3 HeatMap(float t)
{
    t = saturate(t);
    float3 c;
    c.r = smoothstep(0.5, 0.8, t);
    c.g = smoothstep(0.0, 0.5, t) - smoothstep(0.5, 1.0, t);
    c.b = 1.0 - smoothstep(0.0, 0.5, t);
    return c;
}

//=============================================================================
// Main Entry Point
//=============================================================================
float4 main(PSIn input) : SV_Target
{
    // Read depth intervals from interval shading pass
    float front = FrontTex.SampleLevel(LinearClamp, input.Tex, 0);
    float back = BackTex.SampleLevel(LinearClamp, input.Tex, 0);

    // Sky gradient background
    float3 skyTop = float3(0.4, 0.6, 0.9);
    float3 skyMid = float3(0.6, 0.7, 0.9);
    float3 skyBot = float3(0.8, 0.85, 0.95);

    float skyY = input.Tex.y;
    float3 bgColor = lerp(skyBot, skyMid, smoothstep(0.0, 0.5, skyY));
    bgColor = lerp(bgColor, skyTop, smoothstep(0.5, 1.0, skyY));

    // No volume hit - just background
    if (front >= back || front > 100.0)
    {
        return float4(bgColor, 1.0);
    }

    // Reconstruct world-space ray
    float2 ndc = input.Tex * 2.0 - 1.0;
    ndc.y *= -1.0;
    float4 nearWorld = mul(float4(ndc, 0.0, 1.0), Globals.InvViewProj);
    nearWorld /= nearWorld.w;
    float3 rayDir = normalize(nearWorld.xyz - Globals.CameraPos);

    float3 color = float3(0, 0, 0);

    if (Globals.DebugMode == 5)
    {
        // === CLOUD RENDERING ===
        float3 cloudRadiance = float3(0, 0, 0);

        // Multi-sampling loop
        for (int s = 0; s < NUM_SAMPLES; s++)
        {
            // Unique seed per sample
            uint seed = uint(input.Position.x) * 1973u
                      + uint(input.Position.y) * 9277u
                      + uint(s) * 26699u
                      + uint(front * 12345.0);

            cloudRadiance += IntegrateCloud(Globals.CameraPos, rayDir, front, back, seed);
        }
        cloudRadiance /= float(NUM_SAMPLES);

        // Estimate transmittance for background visibility
        uint convergeSeed = uint(input.Position.x * input.Position.y) + 7919u;
        float Tr = EstimateTransmittance(Globals.CameraPos, rayDir, front, back,
                                         Globals.Density * 0.8, convergeSeed);

        // Composite cloud over background
        color = cloudRadiance + bgColor * Tr;
    }
    else if (Globals.DebugMode == 4)
    {
        // Optical depth heat map
        float opticalDepth = (back - front) * Globals.Density;
        color = HeatMap(saturate(opticalDepth * 0.1));
    }
    else
    {
        // Front depth visualization
        color = DepthVis(front);
    }

    // Tone mapping (ACES-ish filmic)
    color = color * 0.6;  // Exposure adjustment
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = saturate(color);

    // Subtle contrast
    color = pow(color, 1.1);

    return float4(color, 1.0);
}