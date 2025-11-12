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
