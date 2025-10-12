
#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut vertexShader(uint vertexID [[vertex_id]]) {
    VSOut out;
    float4 positions[] = {
        float4(-1.0, -1.0, 0.0, 1.0),
        float4( 1.0, -1.0, 0.0, 1.0),
        float4(-1.0,  1.0, 0.0, 1.0),
        float4( 1.0,  1.0, 0.0, 1.0)
    };

    float2 uvs[] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    out.position = positions[vertexID];
    out.uv = uvs[vertexID];
    return out;
}

struct OverlayRect {
    float2 scale;
    float2 offset;
    float opacity;
    bool enabled;
};

struct Params {
    bool inputIsBGRA;
    bool enableSub, enableFol;
    float4x4 videoToNDC;
    OverlayRect sub;
    OverlayRect fol;
};

fragment float4 compositeFrag(VSOut in [[stage_in]],
                              texture2d<float> luma     [[texture(0)]],
                              texture2d<float> chroma   [[texture(1)]],
                              texture2d<float> subTex   [[texture(2)]],
                              texture2d<float> folTex   [[texture(3)]],
                              constant Params& p        [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float2 uv = in.uv;

    // Full-range BT.709
    const float3x3 M = float3x3(float3(1.0,    1.0,    1.0),
                                float3(0.0,   -0.1873, 1.8556),
                                float3(1.5748,-0.4681, 0.0));
    float  Y  = luma.sample(s, uv).r;
    float2 CbCr = chroma.sample(s, uv).rg - float2(0.5, 0.5);
    float3 rgb = M * float3(Y, CbCr.x, CbCr.y);
    float4 base = float4(rgb, 1.0);

    float4 sub = p.enableSub ? subTex.sample(s, p.sub.scale * uv + p.sub.offset) : float4(0);
    float4 fol = p.enableFol ? folTex.sample(s, p.fol.scale * uv + p.fol.offset) : float4(0);

    float4 outc = base;
    outc = sub + outc * (1.0 - sub.a);
    outc = fol + outc * (1.0 - fol.a);
    return outc;
}


fragment float4 compositeFragBGRA(VSOut in [[stage_in]],
                                   texture2d<float> baseTex  [[texture(0)]],
                                   texture2d<float> subTex   [[texture(1)]],
                                   texture2d<float> folTex   [[texture(2)]],
                                   constant Params& p        [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float2 uv = in.uv;

    float4 base = baseTex.sample(s, uv);

    float4 sub = p.enableSub ? subTex.sample(s, p.sub.scale * uv + p.sub.offset) : float4(0);
    float4 fol = p.enableFol ? folTex.sample(s, p.fol.scale * uv + p.fol.offset) : float4(0);

    float4 outc = base;
    outc = sub + outc * (1.0 - sub.a);
    outc = fol + outc * (1.0 - fol.a);
    return outc;
}

