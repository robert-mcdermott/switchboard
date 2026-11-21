// M0 prototype: instanced, additively blended Bézier ribbons with travelling pulses.
// Compiled from source at launch (docs/SPEC.md §9.5).

#include <metal_stdlib>
using namespace metal;

struct EdgeInstance {
    float2 p0;
    float2 p1;
    float2 control;
    float  halfWidth;
    float  phase;
    float4 color;
    float  speed;
    float  density;
    float2 padding;
};

struct Uniforms {
    float2 viewport;   // drawable size in pixels
    float  time;
    float  scale;      // world units to pixels
};

struct EdgeVertex {
    float4 position [[position]];
    float4 color;
    float  along;      // 0 at the source, 1 at the destination
    float  across;     // -1 … 1 across the ribbon
    float  phase;
    float  speed;
    float  density;
};

constant uint kSegments = 24;

vertex EdgeVertex edge_vertex(uint vertexID [[vertex_id]],
                              uint instanceID [[instance_id]],
                              const device EdgeInstance *instances [[buffer(0)]],
                              constant Uniforms &uniforms [[buffer(1)]])
{
    EdgeInstance edge = instances[instanceID];
    float t = float(vertexID / 2) / float(kSegments);
    float side = (vertexID % 2 == 0) ? -1.0 : 1.0;

    // Quadratic Bézier, evaluated by de Casteljau so the tangent falls out for free.
    float2 a = mix(edge.p0, edge.control, t);
    float2 b = mix(edge.control, edge.p1, t);
    float2 point = mix(a, b, t);
    float2 direction = b - a;
    float2 tangent = direction / max(length(direction), 1e-5);
    float2 normal = float2(-tangent.y, tangent.x);

    float2 world = point + normal * side * edge.halfWidth;
    float2 ndc = world * uniforms.scale / (uniforms.viewport * 0.5);

    EdgeVertex out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = edge.color;
    out.along = t;
    out.across = side;
    out.phase = edge.phase;
    out.speed = edge.speed;
    out.density = edge.density;
    return out;
}

fragment float4 edge_fragment(EdgeVertex in [[stage_in]], constant Uniforms &uniforms [[buffer(1)]])
{
    // A bright core inside a soft halo.
    float core = exp(-in.across * in.across * 22.0);
    float halo = exp(-in.across * in.across * 3.5) * 0.22;

    // Comet-shaped pulses that travel from source to destination.
    float travel = fract(in.along * in.density - uniforms.time * in.speed + in.phase);
    float pulse = pow(travel, 7.0);

    float ends = smoothstep(0.0, 0.05, in.along) * smoothstep(1.0, 0.95, in.along);
    float intensity = (0.045 + pulse * 1.5) * (core + halo) * ends;
    return float4(in.color.rgb * intensity, 1.0);
}
