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

// Simple depth-based color gradient
float3 DepthToColor(float depth)
{
    // Rainbow-like gradient based on depth
    float t = saturate(depth / 3.0f);
    
    float3 color;
    if (t < 0.25f)
        color = lerp(float3(0, 0, 1), float3(0, 1, 1), t * 4.0f); // Blue to Cyan
    else if (t < 0.5f)
        color = lerp(float3(0, 1, 1), float3(0, 1, 0), (t - 0.25f) * 4.0f); // Cyan to Green
    else if (t < 0.75f)
        color = lerp(float3(0, 1, 0), float3(1, 1, 0), (t - 0.5f) * 4.0f); // Green to Yellow
    else
        color = lerp(float3(1, 1, 0), float3(1, 0, 0), (t - 0.75f) * 4.0f); // Yellow to Red
    
    return color;
}

// Main interval shading function - ray march through the volume
float4 IntervalShading(float3 rayEntry, float3 rayExit, float3 cameraPos)
{
    // Calculate ray direction and interval length
    float3 rayDir = rayExit - rayEntry;
    float intervalLength = length(rayDir);
    rayDir = normalize(rayDir);
    
    // Number of samples along the ray interval
    const int numSamples = 32;
    float stepSize = intervalLength / float(numSamples);
    
    float4 accumulated = float4(0, 0, 0, 0);
    float3 currentPos = rayEntry;
    
    // March along the ray within the computed interval
    for (int i = 0; i < numSamples; i++)
    {
        // Calculate depth from camera
        float depth = length(currentPos - cameraPos);
        
        // Get color based on depth
        float3 depthColor = DepthToColor(depth);
        
        // Sample opacity based on position
        float opacity = 0.15f * (1.0f - float(i) / float(numSamples)); // Fade towards back
        
        // Front-to-back compositing
        float alpha = opacity;
        accumulated.rgb += depthColor * alpha * (1.0f - accumulated.a);
        accumulated.a += alpha * (1.0f - accumulated.a);
        
        // Early ray termination if fully opaque
        if (accumulated.a >= 0.95f)
            break;
        
        // Move to next sample position
        currentPos += rayDir * stepSize;
    }
    
    return accumulated;
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
        float4 volumeColor = IntervalShading(
            input.RayEntry,
            input.RayExit,
            CameraPosition
        );
        
        // Enhance with base color tint
        volumeColor.rgb *= input.Color.rgb * 1.2f;
        
        return float4(volumeColor.rgb, volumeColor.a * 0.85f);
    }
}
