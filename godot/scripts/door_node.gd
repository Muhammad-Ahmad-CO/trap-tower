class_name TTDoor
extends Node2D

# White rounded-top door, fixed size from tuning.json. Node sits at origin;
# drawing uses level-space coordinates. centre = door centre/base point.

var centre := Vector2.ZERO
var door_w := 54.0
var door_h := 84.0
var fill := Color.WHITE
var outline := Color(0.04, 0.12, 0.27)


func setup(door_dict: Dictionary, tuning: Dictionary) -> void:
	centre = Vector2(float(door_dict.get("x", 0)), float(door_dict.get("y", 0)))
	# Drawing only: door above platforms (z 0), below hazards (z 10).
	z_index = 1
	var dd: Dictionary = tuning.get("door", {})
	door_w = float(dd.get("width", 54))
	door_h = float(dd.get("height", 84))
	fill = TTuning.col(str(dd.get("fill", "#FFFFFF")))
	outline = TTuning.col(str(dd.get("outline", "#0A1F44")))


func door_rect() -> Rect2:
	return Rect2(centre.x - door_w * 0.5, centre.y - door_h, door_w, door_h)


func _draw() -> void:
	var r := door_rect()
	var rad := door_w * 0.5
	var cy := r.position.y + rad
	draw_circle(Vector2(centre.x, cy), rad, fill)
	draw_rect(Rect2(r.position.x, cy, door_w, door_h - rad), fill)
	draw_arc(Vector2(centre.x, cy), rad, PI, TAU, 24, outline, 3.0)
	draw_line(Vector2(r.position.x, cy), Vector2(r.position.x, centre.y), outline, 3.0)
	draw_line(Vector2(r.end.x, cy), Vector2(r.end.x, centre.y), outline, 3.0)
