shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;
// Water surface visuals: the waves here are SHADER-ONLY — physics reads
// WaterSurface.get_height(), which is flat. Never feed VERTEX.y back into gameplay.
//
// Depth-fade: shallow water stays translucent, deep water goes opaque + bluer, so the
// seafloor (and the square map edge past it) fades out instead of showing through. This
// is fragment shading only — get_height() is untouched.

uniform vec4 water_color : source_color = vec4(0.10, 0.38, 0.52, 0.78);
// Slightly darker/bluer for deep water.
uniform vec4 deep_color : source_color = vec4(0.03, 0.14, 0.26, 1.0);
uniform float shallow_alpha = 0.45;
uniform float deep_alpha = 0.96;
// Water column depth (m) over which shallow fades to fully deep.
uniform float depth_fade_m = 6.0;
uniform float wave_height = 0.10;
uniform float wave_speed = 1.1;

uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;

void vertex() {
	float t = TIME * wave_speed;
	VERTEX.y += sin(t + VERTEX.x * 0.55) * sin(t * 0.8 + VERTEX.z * 0.47) * wave_height;
}

void fragment() {
	// Reconstruct the opaque scene's view-space distance behind this water fragment.
	// gl_compatibility: NDC z is [-1, 1], so depth is remapped with * 2.0 - 1.0
	// (Forward+ would leave it as-is). Transparent pass reads the opaque depth buffer.
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth * 2.0 - 1.0);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float scene_dist = -view.z;
	float frag_dist = -VERTEX.z;   // VERTEX is view-space in fragment()
	float water_depth = scene_dist - frag_dist;
	float t = clamp(water_depth / max(depth_fade_m, 0.001), 0.0, 1.0);

	ALBEDO = mix(water_color.rgb, deep_color.rgb, t);
	ALPHA = mix(shallow_alpha, deep_alpha, t);
	ROUGHNESS = 0.12;
	SPECULAR = 0.6;
}
