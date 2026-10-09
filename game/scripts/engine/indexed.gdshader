shader_type canvas_item;
// Draws 8-bit indexed textures (grayscale value = palette index) with a
// 256x1 palette, the way the VGA card did. `brightness` drives fades.

uniform sampler2D palette : filter_nearest;
uniform int transparent_index = -1;
uniform int shadow_index = -1;
uniform float brightness = 1.0;

void fragment() {
	int i = int(round(texture(TEXTURE, UV).r * 255.0));
	if (i == transparent_index) {
		discard;
	}
	if (i == shadow_index) {
		COLOR = vec4(0.0, 0.0, 0.0, 0.45);
	} else {
		vec4 c = texelFetch(palette, ivec2(i, 0), 0);
		COLOR = vec4(c.rgb * brightness, 1.0) * vec4(1.0, 1.0, 1.0, COLOR.a);
	}
}
