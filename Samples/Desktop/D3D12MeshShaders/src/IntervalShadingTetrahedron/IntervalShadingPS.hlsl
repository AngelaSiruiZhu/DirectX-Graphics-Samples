//*********************************************************
// Interval Shading Pixel Shader - Depth Visualization
// Renders depth through volume using ray marching intervals
//*********************************************************

struct MeshOutput
{
    float4 Position : SV_Position;
    float3 WorldPos : POSITION0;
    float3 RayEntry : POSITION1;
    float3 RayExit : POSITION2;
    float4 Color : COLOR;
    uint TriangleID : TEXCOORD0;
};

cbuffer SceneConstants : register(b0)
{
    float4x4 WorldViewProj;
    float4x4 World;
    float3 CameraPosition;
    float Time;
    uint ShowDepth;
    float3 _padding;
};

// Depth to grayscale: White (near) to Dark Gray (far)
// Matches paper convention where larger depth = darker
float3 DepthToColor(float depth)
{
    // Normalize depth to [0, 1] range
    // Assuming depth range of approximately 0-6 units based on camera setup
    float t = saturate(depth / 6.0f);
    
    // Invert: 1.0 (white) for near, 0.0 (black) for far
    float intensity = 1.0f - t;
    
    // Add slight minimum to avoid pure black (makes it easier to see)
    intensity = intensity * 0.9f + 0.1f;
    
    return float3(intensity, intensity, intensity);
}

// Analytical density function - exponential falloff from center
float AnalyticalDensity(float3 pos, float3 center)
{
    float dist = length(pos - center);
    return exp(-dist * 1.5);  // Exponential density falloff
}

// TRUE Interval Shading - NO ray marching!
// Uses analytical integration of density function along the interval
float4 AnalyticalIntervalShading(float3 rayEntry, float3 rayExit, float3 cameraPos)
{
    // Calculate parametric distances
    float tEntry = length(rayEntry - cameraPos);
    float tExit = length(rayExit - cameraPos);
    
    // Invalid interval check
    if (tExit <= tEntry || length(rayExit - rayEntry) < 0.001)
    {
        return float4(0, 0, 0, 0);
    }
    
    // Ray direction
    float3 rayDir = normalize(rayExit - rayEntry);
    
    // Volume center (tetrahedron center at origin)
    float3 volumeCenter = float3(0, 0, 0);
    
    // Analytical integration:
    // For exponential density: integral of exp(-k*t) from tEntry to tExit
    // Result: (exp(-k*tEntry) - exp(-k*tExit)) / k
    
    float k = 1.5;  // Density falloff rate
    float densityEntry = exp(-k * tEntry);
    float densityExit = exp(-k * tExit);
    
    // Analytical integral (closed form - NO LOOP!)
    float integratedDensity = (densityEntry - densityExit) / k;
    
    // Compute average depth for color mapping
    float avgDepth = (tEntry + tExit) * 0.5;
    float3 color = DepthToColor(avgDepth);
    
    // Opacity based on integrated density
    float opacity = saturate(integratedDensity * 2.0);
    
    // Return final color with analytical opacity
    return float4(color * opacity, opacity);
}

float4 main(MeshOutput input) : SV_TARGET
{
    if (ShowDepth == 1)
    {
        // Mode 1: Show depth intervals as visualization
        float entryDepth = length(input.RayEntry - CameraPosition);
        float exitDepth = length(input.RayExit - CameraPosition);
        
        // Show entry depth as color
        float3 color = DepthToColor(entryDepth);
        return float4(color, 0.7f);
    }
    else
    {
        // Mode 2: Full interval shading with depth-based coloring
        float4 volumeColor = AnalyticalIntervalShading(
            input.RayEntry,
            input.RayExit,
            CameraPosition
        );
        
        // Enhance with base color tint
        volumeColor.rgb *= input.Color.rgb * 1.2f;
        
        return float4(volumeColor.rgb, volumeColor.a * 0.85f);
    }
}
