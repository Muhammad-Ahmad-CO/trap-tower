class_name TTDoor
extends Node2D

# White rounded-top door, FIXED size 36x54 (LEVEL_SCHEMA.md Door: a
# schema constant, TTuning.DOOR_W / DOOR_H). The DEPRECATED tuning.json
# `door` entry is never read. Node sits at origin; drawing uses
# level-space coordinates. centre = door centre/base point.
# Trigger rect = drawn rect: door_rect() is both.

var centre := Vector2.ZERO
var door_w := TTuning.DOOR_W
var door_h := TTuning.DOOR_H
var fill := Color.WHITE
var outline := Color(0.04, 0.12, 0.27)


func setup(door_dict: Dictionary, _tuning: Dictionary) -> void:
	centre = Vector2(float(door_dict.get("x", 0)), float(door_dict.get("y", 0)))
	# Drawing only: door above platforms (z 0), below hazards (z 10).
	z_index = 1
	# Size, fill and outline are schema/code constants; the tuning
	# argument is kept for call compatibility and deliberately unused.
	door_w = TTuning.DOOR_W
	door_h = TTuning.DOOR_H


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
