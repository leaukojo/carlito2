shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;
// Water surface visuals (plan §4.4/§8): the waves here are SHADER-ONLY — physics reads
// WaterSurface.get_height(), which is flat. Never feed VERTEX.y back into gameplay.

uniform vec4 water_color : source_color = vec4(0.10, 0.38, 0.52, 0.78);
uniform float wave_height = 0.10;
uniform float wave_speed = 1.1;

void vertex() {
	float t = TIME * wave_speed;
	VERTEX.y += sin(t + VERTEX.x * 0.55) * sin(t * 0.8 + VERTEX.z * 0.47) * wave_height;
}

void fragment() {
	ALBEDO = water_color.rgb;
	ALPHA = water_color.a;
	ROUGHNESS = 0.12;
	SPECULAR = 0.6;
}
