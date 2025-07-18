@tool
class_name VHSTrailsEffect extends CompositorEffect

const FLAG_FIRST_FRAME := 1 << 0
const FLAG_LIGHTEN := 1 << 1
const FLAG_ADDITIVE := 1 << 2
const FLAG_SCREEN := 1 << 3

enum Blending {
	LIGHTEN, ADDITIVE, SCREEN
}

## How long the trail will stay on screen (0.0 = no trails, 1.0 = infinite trails)
@export_range(0.0, 1.0) var trail_persistence := 0.95

## Trail brightness intensity multiplier
@export_range(0.0, 1.0) var trail_intensity := 0.05

## How fast the trail will disappear (0.0 = immediate fadeout, 1.0 = slow fadeout)
@export_range(0.0, 1.0) var trail_decay := 1.0

## Colors darker than this luminance threshold will be ignored
@export_range(0.0, 1.0) var luminance_threshold := 0.01

## How the trails will be blended with the final image
@export var blend_mode := Blending.LIGHTEN

var rd: RenderingDevice

var copy_shader: RID
var copy_pipeline: RID
var trails_shader: RID
var trails_pipeline: RID
var linear_sampler : RID

var context := &"Trails"
var texture_color_copy := &"texture_color_copy"
var texture_trails_pre_buffer := &"texture_trails_pre_buffer"
var texture_trails_post_buffer := &"texture_trails_post_buffer"

var is_first_frame := true

func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	needs_motion_vectors = false
	rd = RenderingServer.get_rendering_device()
	if !rd: return

	RenderingServer.call_on_render_thread(_initialize_compute)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		var rids := [copy_shader, copy_pipeline, trails_shader, trails_pipeline, linear_sampler]

		for rid in rids:
			if rid && rid.is_valid(): rd.free_rid(rid)

###############################################################################
# Everything after this point is designed to run on our rendering thread

func _create_pipeline(shader_file: RDShaderFile) -> Dictionary:
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()

	if shader_spirv.compile_error_compute != "":
		printerr(shader_spirv.compile_error_compute)
		return {}

	var _shader = rd.shader_create_from_spirv(shader_spirv)
	if !_shader.is_valid():
		printerr("Trails: Invalid shader %s" % shader_file.resource_name)
		return {}

	var _pipeline = rd.compute_pipeline_create(_shader)
	if !_pipeline.is_valid():
		printerr("Trails: Invalid compute pipeline %s" % shader_file.resource_name)
		return {}
	
	return {
		&"shader": _shader,
		&"pipeline": _pipeline
	}

func _initialize_compute() -> bool:
	var sampler_state = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_sampler = rd.sampler_create(sampler_state)

	var pipe_res := _create_pipeline(load("res://vhs_trails_effect/copy.glsl"))
	if pipe_res.is_empty(): 
		return false
	copy_shader = pipe_res.shader
	copy_pipeline = pipe_res.pipeline

	pipe_res = _create_pipeline(load("res://vhs_trails_effect/trails.glsl"))
	if pipe_res.is_empty(): 
		return false
	trails_shader = pipe_res.shader
	trails_pipeline = pipe_res.pipeline

	return true

func _get_image_uniform(image: RID, binding: int = 0) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(image)

	return uniform

func _get_sampler_uniform(image: RID, binding: int = 0) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(linear_sampler)
	uniform.add_id(image)

	return uniform

func _recreate_texture(render_scene_buffers: RenderSceneBuffersRD, name: StringName, size: Vector2i, format: RenderingDevice.DataFormat) -> void:
	var was_created := false

	if render_scene_buffers.has_texture(context, name):
		var tf: RDTextureFormat = render_scene_buffers.get_texture_format(context, name)
		if tf.width != size.x || tf.height != size.y:
			render_scene_buffers.clear_context(context)
			was_created = true
	else:
		var usage_bits: int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		render_scene_buffers.create_texture(context, name, format, usage_bits, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, true)
		was_created = true

	# if any texture was re-created (e.g. viewport resize) assume it's a first frame
	if was_created: is_first_frame = true

func _build_flags() -> int:
	var trail_flags := 0

	if is_first_frame: trail_flags |= FLAG_FIRST_FRAME
	
	match blend_mode:
		Blending.LIGHTEN:
			trail_flags |= FLAG_LIGHTEN
		Blending.ADDITIVE:
			trail_flags |= FLAG_ADDITIVE
		Blending.SCREEN:
			trail_flags |= FLAG_SCREEN
		_:
			trail_flags |= FLAG_LIGHTEN

	return trail_flags

func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if rd && callback_type == CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		var render_scene_buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
		if render_scene_buffers:
			var size = render_scene_buffers.get_internal_size()
			if size.x == 0 && size.y == 0:
				return
			
			_recreate_texture(render_scene_buffers, texture_color_copy, size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
			_recreate_texture(render_scene_buffers, texture_trails_pre_buffer, size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
			_recreate_texture(render_scene_buffers, texture_trails_post_buffer, size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)

			var x_groups: int = (size.x - 1) / 8 + 1
			var y_groups: int = (size.y - 1) / 8 + 1
			var z_groups: int = 1

			# 16-bytes aligned
			var push_constant := PackedFloat32Array()
			push_constant.push_back(size.x)
			push_constant.push_back(size.y)
			push_constant.push_back(float(_build_flags()))
			push_constant.push_back(trail_persistence)

			push_constant.push_back(trail_intensity)
			push_constant.push_back(trail_decay)
			push_constant.push_back(luminance_threshold)
			push_constant.push_back(Engine.get_frames_per_second())
			
			push_constant.push_back(RenderingServer.get_frame_setup_time_cpu())
			push_constant.push_back(0)
			push_constant.push_back(0)
			push_constant.push_back(0)

			# push constant with only 4 entries for the copy screen pipline
			var copy_push_constant := push_constant.slice(0, 4)

			var push_constant_bytes := push_constant.to_byte_array()
			var push_constant_size := push_constant.size() * 4

			var copy_push_constant_bytes := copy_push_constant.to_byte_array()
			var copy_push_constant_size := copy_push_constant.size() * 4

			var view_count := render_scene_buffers.get_view_count()

			for view in range(view_count):
				var color_image := render_scene_buffers.get_color_layer(view)
				var color_copy_image := render_scene_buffers.get_texture_slice(context, texture_color_copy, view, 0, 1, 1)
				var trails_pre_buffer_image := render_scene_buffers.get_texture_slice(context, texture_trails_pre_buffer, view, 0, 1, 1)
				var trails_post_buffer_image := render_scene_buffers.get_texture_slice(context, texture_trails_post_buffer, view, 0, 1, 1)

				# 1. copy current frame to backbuffer for reading (screen texture will be write only in the next shader)
				var uniform := _get_image_uniform(color_image)
				var color_uniform_set := UniformSetCacheRD.get_cache(copy_shader, 0, [uniform])

				uniform = _get_image_uniform(color_copy_image)
				var color_copy_uniform_set := UniformSetCacheRD.get_cache(copy_shader, 1, [uniform])

				# rd.draw_command_begin_label("Trails - current frame copy view layer " + str(view), Color.RED)
				var compute_list := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, copy_pipeline)
				rd.compute_list_bind_uniform_set(compute_list, color_uniform_set, 0)
				rd.compute_list_bind_uniform_set(compute_list, color_copy_uniform_set, 1)
				rd.compute_list_set_push_constant(compute_list, copy_push_constant_bytes, copy_push_constant_size)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
				rd.compute_list_end()
				# rd.draw_command_end_label()

				# 2. create and store new post buffer with current frame contributions, composite trails onto current frame
				uniform = _get_image_uniform(color_image)
				color_uniform_set = UniformSetCacheRD.get_cache(trails_shader, 0, [uniform])

				uniform = _get_sampler_uniform(color_copy_image) 
				var current_frame_uniform_set := UniformSetCacheRD.get_cache(trails_shader, 1, [uniform])

				uniform = _get_sampler_uniform(trails_pre_buffer_image)
				var trails_pre_uniform_set := UniformSetCacheRD.get_cache(trails_shader, 2, [uniform])

				uniform = _get_image_uniform(trails_post_buffer_image)
				var trails_post_uniform_set := UniformSetCacheRD.get_cache(trails_shader, 3, [uniform])

				var uniform_sets := [color_uniform_set, current_frame_uniform_set, trails_pre_uniform_set, trails_post_uniform_set]

				# rd.draw_command_begin_label("Trails - composite post buffer view layer " + str(view), Color.RED)
				compute_list = rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, trails_pipeline)
				for i in range(uniform_sets.size()): 
					rd.compute_list_bind_uniform_set(compute_list, uniform_sets[i], i)
				rd.compute_list_set_push_constant(compute_list, push_constant_bytes, push_constant_size)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
				rd.compute_list_end()
				# rd.draw_command_end_label()

				# 3. copy post to pre for the next frame
				uniform = _get_image_uniform(trails_post_buffer_image)
				var post_uniform_set = UniformSetCacheRD.get_cache(copy_shader, 0, [uniform])

				uniform = _get_image_uniform(trails_pre_buffer_image)
				var pre_uniform_set := UniformSetCacheRD.get_cache(copy_shader, 1, [uniform])

				# rd.draw_command_begin_label("Trails - copy post buffer to pre buffer view layer " + str(view), Color.RED)
				compute_list = rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, copy_pipeline)
				rd.compute_list_bind_uniform_set(compute_list, post_uniform_set, 0)
				rd.compute_list_bind_uniform_set(compute_list, pre_uniform_set, 1)
				rd.compute_list_set_push_constant(compute_list, copy_push_constant_bytes, copy_push_constant_size)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
				rd.compute_list_end()
				# rd.draw_command_end_label()

				is_first_frame = false




