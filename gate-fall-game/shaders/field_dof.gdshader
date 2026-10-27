// Depth of field for the battlefield ground only (the troops stay sharp):
// the image is crisp pixel art across the lanes and goes soft toward the
// horizon (far) and the bottom edge (near), like a lens focused on the fight.
// Used by BattleView's Ground sprite (480x270 field image, lanes y 118-232).
shader_type canvas_item;

uniform sampler2D tex_sharp : filter_nearest, repeat_disable;
uniform sampler2D tex_soft : filter_linear, repeat_disable;
// Image y (0 top .. 1 bottom) where the sharp band starts / ends.
uniform float focus_top : hint_range(0.0, 1.0) = 0.43;
uniform float focus_bottom : hint_range(0.0, 1.0) = 0.87;
uniform float focus_falloff : hint_range(0.01, 0.5) = 0.12;
// Blur radius at full strength, in image pixels.
uniform float blur_radius : hint_range(0.0, 12.0) = 3.0;
// Far ground fades a little into the sky colour (aerial perspective).
uniform vec4 haze : source_color = vec4(0.85, 0.80, 0.78, 0.18);

const float GOLDEN = 2.39996323;

void fragment() {
	vec2 uv = UV;
	float far = 1.0 - smoothstep(focus_top - focus_falloff, focus_top, uv.y);
	float near = smoothstep(focus_bottom, focus_bottom + focus_falloff, uv.y);
	float dof = max(far, near);
	vec4 col = texture(tex_sharp, uv);
	if (dof > 0.01) {
		vec2 px = 1.0 / vec2(textureSize(tex_soft, 0));
		vec4 acc = texture(tex_soft, uv);
		float r = blur_radius * dof;
		for (int i = 0; i < 16; i++) {
			float k = (float(i) + 0.5) / 16.0;
			float a = float(i) * GOLDEN;
			acc += texture(tex_soft, uv + vec2(cos(a), sin(a)) * sqrt(k) * r * px);
		}
		col = mix(col, acc / 17.0, smoothstep(0.0, 0.35, dof));
		col.rgb = mix(col.rgb, haze.rgb, haze.a * far);
	}
	COLOR = col;
}
