// HD look for the battle screen ("2.5D pixel art"): drawn over the battlefield,
// under the HUD (PostFx layer 1, Hud layer 2), at the window's full resolution.
// The sprites stay pixel art; the light around them is smooth:
//   bloom      bright pixels (specials, sparks, gold trim) glow softly
//   grading    a little contrast/saturation, warm highlights, cool shadows
//   vignette   darker corners
// Depth blur is not here: it blurs only the ground image (field_dof.gdshader),
// never the troops. Radii are in game pixels (the 320x180 screen), so it looks
// the same at x4 or x6. F2 in battle toggles this layer.
// Works on the Compatibility renderer (no HDR, no mipmaps: plain spiral taps).
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;

group_uniforms bloom;
uniform float bloom_threshold : hint_range(0.0, 1.0) = 0.68;
uniform float bloom_strength : hint_range(0.0, 2.0) = 0.6;
uniform float bloom_radius : hint_range(1.0, 32.0) = 9.0;

group_uniforms grading;
uniform float contrast : hint_range(0.5, 1.5) = 1.06;
uniform float saturation : hint_range(0.0, 2.0) = 1.12;
uniform vec3 highlight_tint : source_color = vec3(1.0, 0.96, 0.88);
uniform vec3 shadow_tint : source_color = vec3(0.90, 0.95, 1.06);
uniform float vignette : hint_range(0.0, 1.0) = 0.38;

const int TAPS = 20;
const float GOLDEN = 2.39996323;

// One game pixel in UV (square: based on screen height = 180 game px).
vec2 game_px(vec2 sps) {
	return vec2(sps.x / sps.y, 1.0) / 180.0;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 px = game_px(SCREEN_PIXEL_SIZE);
	vec3 col = texture(screen_tex, uv).rgb;

	// Bloom: average of the bright part of the neighbourhood.
	vec3 glow = vec3(0.0);
	float wsum = 0.0;
	for (int i = 0; i < TAPS; i++) {
		float k = (float(i) + 0.5) / float(TAPS);
		float a = float(i) * GOLDEN;
		vec2 o = vec2(cos(a), sin(a)) * sqrt(k) * bloom_radius * px;
		vec3 c = texture(screen_tex, uv + o).rgb;
		float w = 1.0 - k * 0.7;
		glow += max(c - vec3(bloom_threshold), vec3(0.0)) * w;
		wsum += w;
	}
	glow /= wsum * max(0.001, 1.0 - bloom_threshold);
	col += glow * bloom_strength;

	// Grading.
	float l = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(l), col, saturation);
	col = (col - 0.5) * contrast + 0.5;
	col *= mix(shadow_tint, highlight_tint, smoothstep(0.15, 0.85, l));

	// Vignette (elliptical, on the screen's aspect).
	vec2 d = (uv - 0.5) * vec2(1.0, 0.8);
	col *= 1.0 - vignette * smoothstep(0.25, 0.75, length(d) * 1.25);

	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
