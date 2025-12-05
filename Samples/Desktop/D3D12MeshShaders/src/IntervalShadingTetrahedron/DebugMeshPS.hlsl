struct VertexOut
{
    float4 Position : SV_Position;
    float4 Color    : COLOR0;
};

float4 main(VertexOut input) : SV_Target
{
    return input.Color;
}
