#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0, rgba16f) uniform restrict readonly image2D color_source_image;
layout(rgba16f, set = 1, binding = 0, rgba16f) uniform restrict writeonly image2D color_target_image;

layout(push_constant, std430) uniform Params {
    vec2 render_size;
    float _pad2;
    float _pad3;
    float _pad4;
    float _pad5;
    float _pad6;
    float _pad7;
    float _pad8;
    float _pad9;
    float _pad10;
    float _pad11;
} params;

void main() {
    ivec2 render_size = ivec2(params.render_size.xy);
    ivec2 texel_coords = ivec2(gl_GlobalInvocationID.xy);

	if ((texel_coords.x >= render_size.x) || (texel_coords.y >= render_size.y)) {
		return;
	}

    vec4 src_data = imageLoad(color_source_image, texel_coords);
    imageStore(color_target_image, texel_coords, src_data);
}