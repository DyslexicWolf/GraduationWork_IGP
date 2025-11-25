extends CharacterBody3D

const SPEED: float = 5.0
@onready var camera: Camera3D = $Camera3D

func _physics_process(_delta: float) -> void:
	if Input.is_action_pressed("move_fly"):
		velocity.y = 5
	else:
		velocity.y = 0
	
	var input_dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)
	
	move_and_slide()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	elif event.is_action_pressed(("escape")):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseMotion:
			camera.rotate_x(-event.relative.y*0.005)
			camera.rotation.x = max(min(camera.rotation.x, deg_to_rad(90)), deg_to_rad(-90))
			rotate_y(-event.relative.x*0.005)
