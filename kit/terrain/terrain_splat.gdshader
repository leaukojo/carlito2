shader_type spatial;
// 4-color splat ground material: albedo colors blended by an
// RGBA splatmap (R=grass, G=dirt, B=sand, A=rock — TerrainGen's channel order). Plain
// arithmetic + one sampler, gl_compatibility-safe; no texture layers by design (plan:
// low-poly color fields). The splatmap is raw weight data, NOT source_color — sRGB
// conversion would bend the weights. UV is HeightmapTerrain's global 0..1 terrain UV,
// identical across render chunks, so splat blending never seams at chunk borders.

uniform vec4 grass_color : source_color = vec4(0.35, 0.55, 0.25, 1.0);
uniform vec4 dirt_color : source_color = vec4(0.52, 0.40, 0.26, 1.0);
uniform vec4 sand_color : source_color = vec4(0.83, 0.76, 0.55, 1.0);
uniform vec4 rock_color : source_color = vec4(0.45, 0.44, 0.42, 1.0);
uniform sampler2D splatmap : filter_linear, repeat_disable, hint_default_black;
// Contrast between the color fields: weights are pow-sharpened and renormalized, so
// the dominant channel wins fast (crisp low-poly borders) instead of long soft fades.
uniform float blend_sharpness : hint_range(1.0, 16.0) = 8.0;
uniform float roughness_value : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 w = pow(texture(splatmap, UV), vec4(blend_sharpness));
	float total = w.r + w.g + w.b + w.a;
	vec3 blend = grass_color.rgb * w.r + dirt_color.rgb * w.g
			+ sand_color.rgb * w.b + rock_color.rgb * w.a;
	// No splatmap bound (hint_default_black) or an empty pixel: plain grass, not black.
	ALBEDO = total > 0.001 ? blend / total : grass_color.rgb;
	ROUGHNESS = roughness_value;
}
