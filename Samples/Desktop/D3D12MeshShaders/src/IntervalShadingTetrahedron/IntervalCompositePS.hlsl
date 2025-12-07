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

struct DepthNeighborhood
{
    float coverage;
    float frontAvg;
    float backAvg;
};

static const float2 kBlurOffsets[9] =
{
    float2(0.0f, 0.0f),
    float2(1.0f, 0.0f),
    float2(-1.0f, 0.0f),
    float2(0.0f, 1.0f),
    float2(0.0f, -1.0f),
    float2(1.0f, 1.0f),
    float2(1.0f, -1.0f),
    float2(-1.0f, 1.0f),
    float2(-1.0f, -1.0f)
};

static const float kBlurWeights[9] =
{
    0.28f,
    0.125f,
    0.125f,
    0.125f,
    0.125f,
    0.045f,
    0.045f,
    0.045f,
    0.045f
};

DepthNeighborhood GatherDepthNeighborhood(float2 uv)
{
    uint width, height;
    FrontTex.GetDimensions(width, height);
    float2 texel = 1.0f / float2(width, height);

    DepthNeighborhood nb;
    nb.coverage = 0.0f;
    nb.frontAvg = 0.0f;
    nb.backAvg = 0.0f;

    [unroll]
    for (int i = 0; i < 9; ++i)
    {
        float2 sampleUV = uv + kBlurOffsets[i] * texel;
        float sFront = FrontTex.SampleLevel(LinearClamp, sampleUV, 0.0f);
        float sBack  = BackTex.SampleLevel(LinearClamp, sampleUV, 0.0f);

        bool valid = (sFront < sBack) && (sFront < 1e30f) && (sBack < 1e30f);
        if (valid)
        {
            float w = kBlurWeights[i];
            nb.coverage += w;
            nb.frontAvg += w * sFront;
            nb.backAvg += w * sBack;
        }
    }

    if (nb.coverage > 0.0f)
    {
        float inv = 1.0f / nb.coverage;
        nb.frontAvg *= inv;
        nb.backAvg *= inv;
    }

    return nb;
}

struct PSIn
{
    float4 Position : SV_Position;
    float2 Tex      : TEXCOORD0;
};

float hash(float3 p)
{
    p = frac(p * 0.3183099 + 0.1);
    p *= 17.0;
    return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(float3 x)
{
    float3 i = floor(x);
    float3 f = frac(x);
    f = f * f * (3.0 - 2.0 * f);

    return lerp(
        lerp(lerp(hash(i + float3(0,0,0)), hash(i + float3(1,0,0)), f.x),
             lerp(hash(i + float3(0,1,0)), hash(i + float3(1,1,0)), f.x), f.y),
        lerp(lerp(hash(i + float3(0,0,1)), hash(i + float3(1,0,1)), f.x),
             lerp(hash(i + float3(0,1,1)), hash(i + float3(1,1,1)), f.x), f.y),
        f.z);
}

float fbm(float3 p)
{
    float f = 0.0;
    float w = 0.5;

    for (int i = 0; i < 6; i++)
    {
        f += w * noise(p);
        p *= 2.0;
        w *= 0.5;
    }

    return f;
}

// for terrain height (noise only in XZ)
float fbm2D(float2 p)
{
    return fbm(float3(p.x, 0.0, p.y));
}


//for cloud density
float GetDensity(float3 p)
{
    float d = fbm(p * 3.0 + float3(0, 0, Globals.Time * 0.5));
    float corrosion = noise(p * 4.0 - float3(0, Globals.Time * 1.0, 0));
    d -= corrosion * 0.2;
    return saturate((d - 0.05) * 2.0);
}

float GetDensityLowQ(float3 p)
{
    float d = noise(p * 3.0 + float3(0, 0, Globals.Time * 0.5));
    float corrosion = noise(p * 4.0 - float3(0, Globals.Time * 1.0, 0));
    d -= corrosion * 0.2;
    return saturate((d - 0.05) * 2.0);
}

float3 DepthToGray(float d)
{
    float v = saturate(d * 0.05);
    v = 1.0 - v;
    v = v * 0.9 + 0.1;
    return float3(v, v, v);
}

float3 HeatMap(float v)
{
    return saturate(float3(
        1.5 * v,
        1.5 * (1.0 - abs(v - 0.5) * 2.0),
        1.5 * (1.0 - v)));
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

float GetTerrainHeight(float3 p, float base, float amp)
{
    float n = fbm2D(p.xz * 0.08);
    n = n * n; 
    return base - n * amp;
}

float3 GetProceduralBackground(float3 rayDir)
{
    float3 skyTop  = float3(0.2, 0.4, 0.8);
    float3 horizon = float3(0.6, 0.7, 0.8);

    float3 col = lerp(horizon, skyTop, pow(max(0, -rayDir.y), 0.8));

    const float groundBaseHeight = 5.0;
    const float terrainAmp       = 15.0;
    const float step             = 0.1;
    const float maxDistance      = 500.0;

    if (rayDir.y > 0.01)
    {
        float maxHeight = groundBaseHeight;
        float minHeight = groundBaseHeight - terrainAmp;

        if (Globals.CameraPos.y < maxHeight)
        {
            float t = (minHeight - Globals.CameraPos.y) / rayDir.y;
            t = max(t, 0.0);

            for (int i = 0; i < 800 && t < maxDistance; ++i)
            {
                float3 p = Globals.CameraPos + rayDir * t;
                float h = GetTerrainHeight(p, groundBaseHeight, terrainAmp);

                if (p.y > h)
                {
                    // Binary refine intersection
                    float t_min = max(t - step, 0.0);
                    float t_max = t;

                    for (int j = 0; j < 5; j++)
                    {
                        float t_mid = 0.5 * (t_min + t_max);
                        float3 p_mid = Globals.CameraPos + rayDir * t_mid;
                        float h_mid = GetTerrainHeight(p_mid, groundBaseHeight, terrainAmp);

                        if (p_mid.y > h_mid)
                            t_max = t_mid;
                        else
                            t_min = t_mid;
                    }

                    t = t_max;
                    p = Globals.CameraPos + rayDir * t;
                    h = GetTerrainHeight(p, groundBaseHeight, terrainAmp);

                    // normal
                    float d = 0.1;
                    float h_x = GetTerrainHeight(p + float3(d, 0, 0), groundBaseHeight, terrainAmp);
                    float h_z = GetTerrainHeight(p + float3(0, 0, d), groundBaseHeight, terrainAmp);

                    float3 normal = -normalize(float3(h - h_x, d, h - h_z));

                    float3 lightDir = normalize(float3(0.5, -1.0, -0.5));
                    float light = saturate(dot(normal, lightDir)) * 0.6 + 0.4;

                    float3 grass = float3(0.1, 0.35, 0.1);
                    float3 dirt  = float3(0.4, 0.3, 0.2);
                    float3 rock  = float3(0.25, 0.25, 0.3);
                    float3 snow  = float3(1.0, 1.0, 1.0);

                    float n = fbm2D(p.xz * 0.5);
                    float3 lowLayer = lerp(grass, dirt, smoothstep(0.45, 0.75, n));

                    float relativeHeight = groundBaseHeight - p.y;
                    
                    float rockMix = smoothstep(5.0, 8.0, relativeHeight + n * 2.0);
                    float3 midLayer = lerp(lowLayer, rock, rockMix);

                    float snowMix = smoothstep(5.0, 8.0, relativeHeight + n * 2.0);
                    snowMix *= smoothstep(0.5, 0.9, -normal.y);

                    float3 ground = lerp(midLayer, snow, snowMix);
                    ground *= light;

                    float fog = 1.0 - exp(-t * 0.005);
                    col = lerp(ground, horizon, fog);
                    break;
                }

                t += step;
            }
        }
    }

    return col;
}

float4 main(PSIn input) : SV_Target
{
    float2 uv = input.Tex;
    float front = FrontTex.SampleLevel(LinearClamp, uv, 0);
    float back  = BackTex.SampleLevel(LinearClamp, uv, 0);
    float tau   = OpticalTex.SampleLevel(LinearClamp, uv, 0);

    float3 color = 0;
    float alpha = 1.0;

    switch (Globals.DebugMode)
    {
    case 0:  color = DepthToGray(front); break;
    case 1:  color = DepthToGray(back);  break;
    case 2:  color = HeatMap(saturate((back - front) * 0.2)); break;
    case 3:  color = HeatMap(saturate(tau * 0.2)); break;

    case 4:
    {
        float T = exp(-tau);
        color = float3(T, T, T);
        break;
    }

    case 5:
    {
        DepthNeighborhood neighbourhood = GatherDepthNeighborhood(uv);
        bool centerValid = (front < back) && (front < 1e30f) && (back < 1e30f);
        float coverageBoost = saturate(neighbourhood.coverage + (centerValid ? 0.25f : 0.0f));
        float edgeBlend = 1.0f - smoothstep(0.3f, 0.95f, coverageBoost);
        float coverageWeight = smoothstep(0.1f, 0.85f, coverageBoost);

        if (neighbourhood.coverage > 0.0f)
        {
            if (!centerValid)
            {
                front = neighbourhood.frontAvg;
                back = neighbourhood.backAvg;
                centerValid = (front < back);
            }
            else
            {
                float blendWeight = edgeBlend * 0.75f;
                front = lerp(front, neighbourhood.frontAvg, blendWeight);
                back = lerp(back, neighbourhood.backAvg, blendWeight);
            }
        }

        float hullPadding = edgeBlend * 0.45f;
        front = max(front - hullPadding, 0.0f);
        back += hullPadding;

        bool hasVolume = (centerValid || coverageWeight > 0.0f) && (front < back);

        //cloud rendering
        float cloudTransmittance = 1.0;
        float3 accumulatedLight = 0;

        float3 lightPos = float3(0.0, -35.0, 0.0);
        float3 lightColor = float3(1.0, 0.9, 0.7) * 0.24;

        float2 ndc = uv * 2.0 - 1.0;
        ndc.y = -ndc.y;

        float4 clipFar = float4(ndc, 1.0, 1.0);
        float4 worldFar = mul(clipFar, Globals.InvViewProj);
        worldFar /= worldFar.w;

        float3 rayDir = normalize(worldFar.xyz - Globals.CameraPos);

        if (hasVolume)
        {
            float dist = front;
            float baseStep = 0.02f;
            float stepSize = lerp(baseStep * 1.2f, baseStep, coverageWeight);
            float fadeWidthBase = lerp(0.3f, 0.55f, coverageWeight);
            float densityScale = lerp(0.3f, 1.0f, coverageWeight);

            for (int i = 0; i < 64; i++)
            {
                if (dist >= back || cloudTransmittance < 0.01f) break;

                float3 p = Globals.CameraPos + rayDir * dist;

                float densityBase = GetDensity(p * Globals.Density);
                float fadeFront = saturate((dist - front) / fadeWidthBase);
                float fadeBack  = saturate((back - dist) / fadeWidthBase);
                float edgeFade = pow(fadeFront * fadeBack, lerp(0.55f, 1.0f, coverageWeight));
                float density = saturate(densityBase * 2.0f) * edgeFade * densityScale;

                if (density > 0.0001f)
                {
                    float3 lDir = normalize(lightPos - p);
                    float distToLight = length(lightPos - p);

<<<<<<< HEAD
                    float shadowDensity = 0.0f;
                    shadowDensity += GetDensity(p * 0.75f * Globals.Density);
                    shadowDensity += GetDensity(p * 0.50f * Globals.Density);
                    shadowDensity += GetDensity(p * 0.25f * Globals.Density);

                    float directT   = exp(-shadowDensity * 1.5f);
                    float scatterT  = exp(-shadowDensity * 0.5f);
                    float attenuation = 1.0f / (0.1f + distToLight * distToLight * 0.05f);

                    float3 sunColor = float3(1.0,0.95,0.9) * 0.5f;
                    float3 ambient  = float3(0.6,0.6,0.6);

                    float3 incoming =
                        lightColor * (directT + scatterT * 0.5f) * attenuation
                        + sunColor + ambient;
=======
                    // Shadow march
                    float shadowDensity = 0;
                    shadowDensity += GetDensity((p + lDir * 2.0) * Globals.Density);
                    shadowDensity += GetDensity((p + lDir * 4.0) * Globals.Density);
                    shadowDensity += GetDensity((p + lDir * 8.0) * Globals.Density);

                    float directT   = exp(-shadowDensity * 1.0);
                    float scatterT  = exp(-shadowDensity * 0.5);
                    
                    // Distance attenuation
                    float attenuation = 1.0 / (1.0 + distToLight * distToLight * 0.005);

                    float3 sunColor = float3(1.0,0.95,0.9) * 0.5;
                    float3 ambient  = float3(0.6,0.6,0.7) * 0.8;

                    float3 incoming =
                        lightColor * 100 * (directT + scatterT * 0.001) * attenuation
                        + ambient;
>>>>>>> refs/remotes/origin/Experiment

                    float stepTransmittance = exp(-density * stepSize);
                    float3 scattered = incoming * density * stepSize;

                    accumulatedLight += scattered * cloudTransmittance;
                    cloudTransmittance *= stepTransmittance;
                }

                dist += stepSize;
            }
        }

        float3 skyColor = GetProceduralBackground(rayDir);
<<<<<<< HEAD
        float safeTrans = lerp(1.0f, cloudTransmittance, coverageWeight);
        float3 finalCloud = accumulatedLight + skyColor * safeTrans;
        finalCloud = lerp(skyColor, finalCloud, coverageWeight);
=======

        // Visualize light source (Sun)
        float3 lVec = normalize(lightPos - Globals.CameraPos);
        float sun = pow(max(0, dot(rayDir, lVec)), 10000.0);
        skyColor += float3(1.0, 0.8, 0.6) * sun * 100.0;

        float3 finalCloud = accumulatedLight + skyColor * cloudTransmittance;
>>>>>>> refs/remotes/origin/Experiment

        // God rays
        float4 lightClip = mul(float4(lightPos, 1.0), Globals.ViewProj);
        float2 lightScreen = lightClip.xy / lightClip.w;
        lightScreen = lightScreen * 0.5 + 0.5;
        lightScreen.y = 1.0 - lightScreen.y;

        float2 delta = (uv - lightScreen);
<<<<<<< HEAD
        int samples = 32;
        float density = 0.9f;
        float weight  = 0.008f;
        float decay   = 0.97f;

        delta *= (density / samples);

        float2 coord = uv;
        float illuminationDecay = 1.0f;
=======
        int samples = 64;
        float density = 0.5;
        float weight  = 0.12; 
        float decay   = 0.96; 

        // Pre-calculate air attenuation
        float airDist = length(Globals.CameraPos - lightPos);
        float airAtten = 1.0 / (1.0 + airDist * airDist * 0.01);

        delta *= (density / samples);

        // jitter to reduce banding
        float jitter = hash(float3(uv * 1024.0, 0.0));
        float2 coord = uv - delta * jitter;

        float illuminationDecay = 1.0;
>>>>>>> refs/remotes/origin/Experiment
        float3 godRayColor = 0;

        for (int i = 0; i < samples; i++)
        {
            coord -= delta;

            float sFront = FrontTex.SampleLevel(LinearClamp, coord, 0.0f);
            float sBack  = BackTex.SampleLevel(LinearClamp, coord, 0.0f);

            float sampleT = 0.0f;

            if (sFront < sBack)
            {
                float3 r = normalize(GetWorldPos(coord, sBack) - Globals.CameraPos);
                float stepLen = (sBack - sFront) / 3.0f;

                float3 p1 = Globals.CameraPos + r * (sFront + stepLen * 0.5f);
                float3 p2 = Globals.CameraPos + r * (sFront + stepLen * 1.5f);
                float3 p3 = Globals.CameraPos + r * (sFront + stepLen * 2.5f);

                float maxD = max(max(GetDensityLowQ(p1 * Globals.Density),
                                     GetDensityLowQ(p2 * Globals.Density)),
                                     GetDensityLowQ(p3 * Globals.Density));

                float block = smoothstep(0.2f, 0.6f, maxD);
                sampleT = (1.0f - block) * coverageWeight;

<<<<<<< HEAD
                float distToLight = length(p2);
                float atten = 1.0f / (0.1f + distToLight * distToLight * 0.2f);
=======
                float distToLight = length(p2 - lightPos);
                float atten = 1.0 / (1.0 + distToLight * distToLight * 0.01);
>>>>>>> refs/remotes/origin/Experiment
                sampleT *= atten;
            }
            else
            {
                sampleT = airAtten;
            }

            godRayColor += sampleT * illuminationDecay * weight;
            illuminationDecay *= decay;
        }

        color = finalCloud + godRayColor * float3(0.5, 0.4, 0.3) * coverageWeight;
        break;
        }
    }

    return float4(color, alpha);
}
