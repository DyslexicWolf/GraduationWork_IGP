shader_type spatial;
render_mode cull_disabled;

uniform float min_height = 0.0;
uniform float max_height = 48.0;

uniform vec3 color1 : source_color = vec3(0.4, 0.15, 0.1); // Dark red/brown
uniform vec3 color2 : source_color = vec3(0.55, 0.35, 0.2); // Brown
uniform vec3 color3 : source_color = vec3(0.75, 0.6, 0.4); // Light brown
uniform vec3 color4 : source_color = vec3(0.6, 0.8, 0.5); // Light greenor


void fragment() {
	//get the world position of the vertex
	//INV_VIEW_MATRIX, transforms the location of the pixels on your screen to world coords (use this if you want world coords)
	//MODEL_MATRIX, transforms the location of the coords of a model in modelspace to world coords
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	
	// Calculate height factor (0.0 to 1.0)
	float height_factor = clamp((world_pos.y - min_height) / (max_height - min_height), 0.0, 1.0);
	
	
	vec3 color;
	if (height_factor < 0.33) {
	color = mix(color1, color2, height_factor * 3.0);
	} 
	else if (height_factor < 0.66) {
	color = mix(color2, color3, (height_factor - 0.33) * 3.0);
	} 
	else {
	color = mix(color3, color4, (height_factor - 0.66) * 3.0);
	}
	
	ALBEDO = color;
}