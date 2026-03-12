#include <metal_stdlib>
using namespace metal;

// MARK: - Shared Data Structures

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct RipplePoint {
    float2 center;      // normalized UV position (0-1)
    float startTime;    // when the ripple was created
    float padding;      // alignment padding
};

struct Uniforms {
    float time;           // elapsed time in seconds
    int   rippleCount;    // number of active ripples
    float aspectRatio;    // width / height for circular ripples
    float colorStrength;  // 0–1 blend strength for peak/trough tinting
    float4 peakColor;     // colour at wave crests  (offset 16, 16-byte aligned)
    float4 troughColor;   // colour at wave valleys (offset 32)
};

// MARK: - Vertex Shader

// Accepts a buffer of float4 where .xy = clip-space position, .zw = UV
vertex VertexOut waterVertexShader(
    uint vertexID [[vertex_id]],
    constant float4* vertices [[buffer(0)]])
{
    VertexOut out;
    out.position = float4(vertices[vertexID].xy, 0.0, 1.0);
    out.texCoord = vertices[vertexID].zw;
    return out;
}

// MARK: - Fragment Shader

fragment float4 waterFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> backgroundTex [[texture(0)]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant RipplePoint* ripples [[buffer(1)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float2 uv         = in.texCoord;
    float2 totalOffset = float2(0.0);

    // Accumulate the strongest peak / trough signal across all ripples (0–1)
    float peakTint   = 0.0;
    float troughTint = 0.0;

    for (int i = 0; i < uniforms.rippleCount; i++) {
        float2 diff = uv - ripples[i].center;

        // Aspect-correct distance so ripples appear circular on screen
        float2 corrected = float2(diff.x * uniforms.aspectRatio, diff.y);
        float dist = length(corrected);

        if (dist < 0.001) continue;

        float age = uniforms.time - ripples[i].startTime;
        if (age < 0.0 || age > 3.0) continue;

        // Wave front expands outward at 0.45 screen-height units per second
        float waveRadius = age * 0.45;

        // Amplitude decays exponentially with age
        float amplitude = 0.028 * exp(-age * 1.6);

        // Spatial and angular frequency of the ripple rings
        float frequency  = 42.0;
        float angularFreq = 20.0;

        // Narrow Gaussian envelope centred on the expanding wave front
        float distFromWave = dist - waveRadius;
        float envelope = exp(-distFromWave * distFromWave * 220.0);

        // Raw sine value (-1 to +1): +1 = crest, -1 = trough
        float rawSine = sin(dist * frequency - age * angularFreq);

        // UV displacement uses amplitude-scaled value
        float displacement = rawSine * amplitude * envelope;
        float2 uvDir = normalize(diff);
        totalOffset += uvDir * displacement;

        // Tint signal: envelope gates it to the wave front region only
        float waveSignal = rawSine * envelope;          // -1..+1 at wave front
        peakTint   = max(peakTint,   max(0.0,  waveSignal));
        troughTint = max(troughTint, max(0.0, -waveSignal));
    }

    // Sample background at distorted UV
    float2 sampleUV = clamp(uv + totalOffset, float2(0.001), float2(0.999));
    float4 color = backgroundTex.sample(s, sampleUV);

    // Blend peak (crest) and trough (valley) colours onto the sample
    float strength = uniforms.colorStrength;
    color = mix(color, uniforms.peakColor,   peakTint   * strength);
    color = mix(color, uniforms.troughColor, troughTint * strength);

    return color;
}
