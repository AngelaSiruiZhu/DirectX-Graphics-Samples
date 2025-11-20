//*********************************************************
// Fullscreen vertex shader
//*********************************************************

struct VSOut
{
    float4 Position : SV_Position;
    float2 Tex      : TEXCOORD0;
};

VSOut main(uint vid : SV_VertexID)
{
    VSOut o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.Position = float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
    o.Tex = float2(p.x, 1.0f - p.y);
    return o;
}
