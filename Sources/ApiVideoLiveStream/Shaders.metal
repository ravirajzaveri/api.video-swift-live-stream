
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
    float2 offset;   // Normalized top-left corner (0-1 in UV space)
    float2 size;     // Normalized width/height relative to video frame
    float  opacity;  // 0.0 - 1.0 alpha multiplier
    uint   enabled;  // 0 = hidden, 1 = visible
    float  padding;  // Align to 16 bytes
};

struct Params {
    uint inputIsBGRA;
    uint reserved0;
    uint reserved1;
    uint reserved2;
    float4x4 videoToNDC;
    OverlayRect chat;
    OverlayRect sub;
    OverlayRect fol;
};

inline float4 sampleOverlay(texture2d<float> tex,
                            constant OverlayRect &rect,
                            float2 uv,
                            sampler s) {
    if (rect.enabled == 0) {
        return float4(0.0);
    }

    // Normalize incoming UV into overlay-local coordinates
    float2 size = max(rect.size, float2(1e-6));
    float2 local = (uv - rect.offset) / size;

    if (any(local < float2(0.0)) || any(local > float2(1.0))) {
        return float4(0.0);
    }

    float4 color = tex.sample(s, local);
    color.a *= rect.opacity;
    return color;
}

fragment float4 compositeFrag(VSOut in [[stage_in]],
                              texture2d<float> luma     [[texture(0)]],
                              texture2d<float> chroma   [[texture(1)]],
                              texture2d<float> chatTex  [[texture(2)]],
                              texture2d<float> subTex   [[texture(3)]],
                              texture2d<float> folTex   [[texture(4)]],
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

    float4 chat = sampleOverlay(chatTex, p.chat, uv, s);
    float4 sub  = sampleOverlay(subTex,  p.sub,  uv, s);
    float4 fol  = sampleOverlay(folTex,  p.fol,  uv, s);

    float4 outc = base;
    outc = chat + outc * (1.0 - chat.a);
    outc = sub  + outc * (1.0 - sub.a);
    outc = fol  + outc * (1.0 - fol.a);
    return outc;
}


fragment float4 compositeFragBGRA(VSOut in [[stage_in]],
                                   texture2d<float> baseTex  [[texture(0)]],
                                   texture2d<float> chatTex  [[texture(1)]],
                                   texture2d<float> subTex   [[texture(2)]],
                                   texture2d<float> folTex   [[texture(3)]],
                                   constant Params& p        [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float2 uv = in.uv;

    float4 base = baseTex.sample(s, uv);

    float4 chat = sampleOverlay(chatTex, p.chat, uv, s);
    float4 sub  = sampleOverlay(subTex,  p.sub,  uv, s);
    float4 fol  = sampleOverlay(folTex,  p.fol,  uv, s);

    float4 outc = base;
    outc = chat + outc * (1.0 - chat.a);
    outc = sub  + outc * (1.0 - sub.a);
    outc = fol  + outc * (1.0 - fol.a);
    return outc;
}
