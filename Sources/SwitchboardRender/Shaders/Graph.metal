// Switchboard's graph shaders (docs/SPEC.md §9.5). Compiled from source at launch.
//
// Everything is drawn into a 16-bit float scene, bloomed, then tone-mapped onto the
// screen. World space has y up; one world unit is `scale` pixels.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewport;   // pixels
    float2 center;     // world position at the middle of the view
    float  scale;      // pixels per world unit
    float  time;
    float  pulseGain;  // 0 in the Still profile
    float  bloom;
    float  grain;
    float  gridAlpha;
    float  backing;    // pixels per point
    float  markScale;  // pixels per world unit for sizes, slower than scale when zoomed in
    float4 field;      // the theme's background
    float4 grid;       // the theme's graph paper
};

struct EdgeInstance {
    float2 p0;
    float2 p1;
    float2 control;
    float  halfWidth;
    float  phase;
    float4 color;
    float  speed;
    float  density;
    float  glow;
    float  pulse;
};

struct NodeInstance {
    float2 center;
    float  radius;
    float  icon;
    float4 color;
    float4 ring;
    float  birth;
    float  intensity;
    float  kind;
    float  padding;
};

struct LabelInstance {
    float2 anchor;
    float2 offset;
    float2 size;
    float2 padding;
    float4 uv;
    float4 color;
};

// MARK: Fullscreen

struct Fullscreen {
    float4 position [[position]];
    float2 uv;
};

vertex Fullscreen fullscreen_vertex(uint vertexID [[vertex_id]])
{
    float2 corner = float2((vertexID << 1) & 2, vertexID & 2);
    Fullscreen out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

// A faint grid that pans and zooms with the graph, brightest near the centre.
fragment float4 field_fragment(Fullscreen in [[stage_in]], constant Uniforms &u [[buffer(1)]])
{
    float2 pixel = float2(in.position.x - u.viewport.x * 0.5, u.viewport.y * 0.5 - in.position.y);
    float2 world = u.center + pixel / u.scale;
    const float spacing = 100.0;
    float2 toLine = abs(fract(world / spacing - 0.5) - 0.5) * spacing * u.scale;
    float line = 1.0 - smoothstep(0.0, 1.3 * u.backing, min(toLine.x, toLine.y));
    float falloff = exp(-length(world) / 900.0);
    float3 grid = u.grid.rgb * line * u.gridAlpha * (0.3 + 0.7 * falloff);
    return float4(grid, 1.0);
}

// MARK: Edges

struct EdgeVertex {
    float4 position [[position]];
    float4 color;
    float  along;    // 0 at the source, 1 at the destination
    float  across;   // in half-widths; the ribbon is drawn wider than its core to hold the halo
    float  phase;
    float  speed;
    float  density;
    float  glow;
    float  pulse;
};

constant uint  kSegments = 24;
constant float kHalo = 2.6;

vertex EdgeVertex edge_vertex(uint vertexID [[vertex_id]],
                              uint instanceID [[instance_id]],
                              const device EdgeInstance *edges [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]])
{
    EdgeInstance edge = edges[instanceID];
    float t = float(vertexID / 2) / float(kSegments);
    float side = (vertexID % 2 == 0) ? -1.0 : 1.0;

    // Quadratic Bézier by de Casteljau; the tangent falls out for free.
    float2 a = mix(edge.p0, edge.control, t);
    float2 b = mix(edge.control, edge.p1, t);
    float2 direction = b - a;
    float2 tangent = direction / max(length(direction), 1e-5);
    float2 normal = float2(-tangent.y, tangent.x);

    // Width is set in pixels so a thin edge never vanishes when zoomed out.
    float natural = edge.halfWidth * u.markScale;
    float floorWidth = 0.7 * u.backing;
    float halfPixels = max(natural, floorWidth);
    // An edge held at its minimum width is drawn fainter instead, so a zoomed-out view of
    // thousands of edges thins out rather than turning solid.
    float thin = mix(0.4, 1.0, saturate(natural / floorWidth));
    float2 pixel = (mix(a, b, t) - u.center) * u.scale + normal * side * halfPixels * kHalo;

    EdgeVertex out;
    out.position = float4(pixel / (u.viewport * 0.5), 0.0, 1.0);
    out.color = edge.color;
    out.along = t;
    out.across = side * kHalo;
    out.phase = edge.phase;
    out.speed = edge.speed;
    out.density = edge.density;
    out.glow = edge.glow * thin;
    out.pulse = edge.pulse * thin;
    return out;
}

fragment float4 edge_fragment(EdgeVertex in [[stage_in]], constant Uniforms &u [[buffer(1)]])
{
    float x = in.across;
    float core = exp(-x * x * 1.7);
    float halo = exp(-x * x * 0.42) * 0.22;

    // Comet-shaped pulses running from source to destination.
    float travel = fract(in.along * in.density - u.time * in.speed + in.phase);
    float comet = pow(travel, 7.0);

    float ends = smoothstep(0.0, 0.04, in.along) * smoothstep(1.0, 0.96, in.along);
    float intensity = (in.glow + comet * in.pulse * u.pulseGain) * (core + halo) * ends;
    return float4(in.color.rgb * intensity, 1.0);
}

// MARK: Nodes

struct NodeVertex {
    float4 position [[position]];
    float2 local;        // pixels from the node's centre, y up
    float  radius;       // pixels
    float4 color;
    float4 ring;
    float  birth;
    float  intensity;
    float  icon;
    float  kind;
};

vertex NodeVertex node_vertex(uint vertexID [[vertex_id]],
                              uint instanceID [[instance_id]],
                              const device NodeInstance *nodes [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]])
{
    NodeInstance node = nodes[instanceID];
    float2 corner = float2(vertexID & 1, vertexID >> 1) * 2.0 - 1.0;
    float radius = max(node.radius * u.markScale, 1.6 * u.backing);
    // Room around the disc for its glow, and, only while a node is new, for the ring that
    // marks its arrival. Keeping settled nodes small matters: with thousands on screen,
    // the area of these quads is most of what the GPU has to shade.
    float age = u.time - node.birth;
    bool arriving = u.pulseGain > 0.0 && age >= 0.0 && age < 1.6;
    float reach = radius * 2.4 + (arriving ? 34.0 : 8.0) * u.backing;

    NodeVertex out;
    out.local = corner * reach;
    out.position = float4(((node.center - u.center) * u.scale + out.local) / (u.viewport * 0.5), 0.0, 1.0);
    out.radius = radius;
    out.color = node.color;
    out.ring = node.ring;
    out.birth = node.birth;
    out.intensity = node.intensity;
    out.icon = node.icon;
    out.kind = node.kind;
    return out;
}

constant float kIconSlot = 64.0;
constant float kIconAtlas = 2048.0;

fragment float4 node_fragment(NodeVertex in [[stage_in]],
                              constant Uniforms &u [[buffer(1)]],
                              texture2d<float> icons [[texture(0)]],
                              sampler smooth [[sampler(0)]])
{
    float d = length(in.local);
    float r = in.radius;
    float edge = u.backing;
    float disc = 1.0 - smoothstep(r - edge, r + edge, d);
    float3 base = in.color.rgb * in.intensity;

    // Glow outside the disc.
    float glow = exp(-max(d - r, 0.0) / (r * 0.6 + 2.5 * u.backing)) * 0.26 * (1.0 - disc);

    // The body: the host is a ring with a core; everything else a softly shaded disc.
    float3 body;
    if (in.kind < 0.5) {
        float shell = smoothstep(r * 0.62, r * 0.78, d);
        float coreDot = 1.0 - smoothstep(r * 0.22, r * 0.30, d);
        body = base * (0.10 + shell + coreDot);
    } else {
        body = base * (0.55 + 0.45 * (1.0 - d / r));
    }

    // App icon, inset in the disc.
    if (in.icon >= 0.0) {
        float2 q = float2(in.local.x, -in.local.y) / (r * 0.80) * 0.5 + 0.5;
        if (all(q >= 0.0) && all(q <= 1.0)) {
            float column = fmod(in.icon, 32.0);
            float row = floor(in.icon / 32.0);
            float2 uv = (float2(column, row) + q) * kIconSlot / kIconAtlas;
            float4 texel = icons.sample(smooth, uv);
            body = mix(base * 0.16, texel.rgb / max(texel.a, 1e-4), texel.a);
        }
    }

    // Trust or exposure ring just outside the disc.
    float ringCentre = r + 3.5 * u.backing;
    float ringBand = (1.0 - smoothstep(0.8 * u.backing, 1.8 * u.backing, abs(d - ringCentre))) * in.ring.a;

    // An expanding ring for the first moments of a node's life.
    float arrival = 0.0;
    float age = u.time - in.birth;
    if (u.pulseGain > 0.0 && age >= 0.0 && age < 1.6) {
        float at = r + age * 16.0 * u.backing;
        arrival = (1.0 - smoothstep(0.0, 1.6 * u.backing, abs(d - at))) * (1.0 - age / 1.6) * 0.6;
    }

    float3 colour = body * disc + base * glow + in.ring.rgb * ringBand + in.color.rgb * arrival;
    // Premultiplied: the disc hides what is behind it, the glow adds to it.
    return float4(colour, disc);
}

// MARK: Bloom

// Four bilinear taps one texel out: a 4x4 box, optionally keeping only bright areas.
fragment float4 downsample_fragment(Fullscreen in [[stage_in]],
                                    texture2d<float> source [[texture(0)]],
                                    sampler smooth [[sampler(0)]],
                                    constant float4 &params [[buffer(0)]])
{
    float2 texel = 1.0 / float2(source.get_width(), source.get_height());
    float3 colour = source.sample(smooth, in.uv + texel * float2(-1.0, -1.0)).rgb
                  + source.sample(smooth, in.uv + texel * float2( 1.0, -1.0)).rgb
                  + source.sample(smooth, in.uv + texel * float2(-1.0,  1.0)).rgb
                  + source.sample(smooth, in.uv + texel * float2( 1.0,  1.0)).rgb;
    colour *= 0.25;
    if (params.x > 0.0) {
        float brightness = max(colour.r, max(colour.g, colour.b));
        colour *= smoothstep(params.x, params.x + params.y, brightness);
    }
    return float4(colour, 1.0);
}

// 3x3 tent, blended additively onto the level above.
fragment float4 upsample_fragment(Fullscreen in [[stage_in]],
                                  texture2d<float> source [[texture(0)]],
                                  sampler smooth [[sampler(0)]])
{
    float2 texel = 1.0 / float2(source.get_width(), source.get_height());
    float3 colour = float3(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float weight = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
            colour += source.sample(smooth, in.uv + texel * float2(x, y)).rgb * weight;
        }
    }
    return float4(colour / 16.0, 1.0);
}

// MARK: Composite

static float hash21(float2 p)
{
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

fragment float4 composite_fragment(Fullscreen in [[stage_in]],
                                   texture2d<float> scene [[texture(0)]],
                                   texture2d<float> bloom [[texture(1)]],
                                   sampler smooth [[sampler(0)]],
                                   constant Uniforms &u [[buffer(1)]])
{
    float3 light = scene.sample(smooth, in.uv).rgb + bloom.sample(smooth, in.uv).rgb * u.bloom;
    // Roll highlights off instead of clipping them.
    light = 1.0 - exp(-light * 1.25);

    float2 fromCentre = (in.uv - 0.5) * float2(u.viewport.x / u.viewport.y, 1.0);
    float vignette = smoothstep(1.05, 0.25, length(fromCentre));
    float3 field = u.field.rgb * mix(0.55, 1.25, vignette);

    float3 colour = field + light;
    colour += (hash21(in.position.xy + fract(u.time) * 61.0) - 0.5) * u.grain;
    return float4(saturate(colour), 1.0);
}

// MARK: Labels

struct LabelVertex {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex LabelVertex label_vertex(uint vertexID [[vertex_id]],
                                uint instanceID [[instance_id]],
                                const device LabelInstance *labels [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]])
{
    LabelInstance label = labels[instanceID];
    float2 corner = float2(vertexID & 1, vertexID >> 1);
    // Snap to whole pixels so text stays crisp while the graph moves.
    float2 origin = floor((label.anchor - u.center) * u.scale + label.offset + 0.5);
    float2 pixel = origin + float2(corner.x * label.size.x, -corner.y * label.size.y);

    LabelVertex out;
    out.position = float4(pixel / (u.viewport * 0.5), 0.0, 1.0);
    out.uv = mix(label.uv.xy, label.uv.zw, corner);
    out.color = label.color;
    return out;
}

fragment float4 label_fragment(LabelVertex in [[stage_in]],
                               texture2d<float> glyphs [[texture(0)]],
                               sampler smooth [[sampler(0)]])
{
    float coverage = glyphs.sample(smooth, in.uv).r * in.color.a;
    return float4(in.color.rgb * coverage, coverage);
}
