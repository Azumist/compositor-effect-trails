#[compute]
#version 450

#define FLAG_FIRST_FRAME uint(1 << 0)
#define FLAG_LIGHTEN uint(1 << 1)
#define FLAG_ADDITIVE uint(1 << 2)
#define FLAG_SCREEN uint(1 << 3)

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) restrict writeonly uniform image2D color_image;
layout(set = 1, binding = 0) uniform sampler2D current_frame_texture;
layout(set = 2, binding = 0) uniform sampler2D trails_pre_buffer;
layout(set = 3, binding = 0, rgba16f) restrict writeonly uniform image2D trails_post_buffer;

layout(push_constant, std430) uniform Params {
    vec2 render_size;
    float flags;
    float trail_persistence;
    float trail_intensity;
    float trail_decay;
    float luminance_threshold;
    float fps;
    float delta;
    float _pad0;
    float _pad1;
    float _pad2;
} params;

void main() {
    ivec2 render_size = ivec2(params.render_size.xy);
    ivec2 texel_coords = ivec2(gl_GlobalInvocationID.xy);

    if ((texel_coords.x >= render_size.x) || (texel_coords.y >= render_size.y)) {
        return;
    }

    vec2 uv = vec2(texel_coords) / render_size;
    vec4 current_color = texture(current_frame_texture, uv);
    uint flags = uint(params.flags);

    if (bool(flags & FLAG_FIRST_FRAME)) {
        // display current frame without trails, clear post buffer and fill it black
        imageStore(color_image, texel_coords, current_color); 
        imageStore(trails_post_buffer, texel_coords, vec4(vec3(0), 1.0));
        return;
    }

    vec4 trail_color = texture(trails_pre_buffer, uv);

    // luminance threshold
    float trail_luminance = dot(trail_color.rgb, vec3(0.299, 0.587, 0.114));
    float adaptive_threshold = params.luminance_threshold * 2.0;
    trail_color *= trail_luminance < adaptive_threshold ? vec4(0.0) : vec4(1.0);

    // decay
    float decay_factor = pow(params.trail_persistence, params.delta * params.fps);
    trail_color *= decay_factor * params.trail_decay;

    // blending (script ensures only one of these flags is active at a time)
    float lighten_flag = float(bool(flags & FLAG_LIGHTEN));
    float additive_flag = float(bool(flags & FLAG_ADDITIVE));
    float screen_flag = float(bool(flags & FLAG_SCREEN));

    vec4 current_color_trails_imposed = max(current_color, trail_color * params.trail_intensity) * lighten_flag +
        (current_color + trail_color * params.trail_intensity) * additive_flag +
        (vec4(1.0) - (vec4(1.0) - current_color) * (vec4(1.0) - trail_color * params.trail_intensity)) * screen_flag;

    // compose
    imageStore(color_image, texel_coords, current_color_trails_imposed);
    
    // feed post buffer to pre buffer
    vec4 trails_output = max(trail_color, current_color);
    imageStore(trails_post_buffer, texel_coords, trails_output); 
}