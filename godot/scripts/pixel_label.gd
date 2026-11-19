class_name TTPixelLabel
extends Node2D

# One line of pixel text as a Node2D. `text`, `pixel_size`, `color`,
# `align`, `width` (line box for centre/right align). Redraws on change.
# (Separate file from TTPixelFont: a script cannot reference its own
# class_name from an inner class.)

var text := ""
var pixel_size := 5
var color := Color.WHITE
var align := HORIZONTAL_ALIGNMENT_LEFT
var width := 0.0


func set_text(t: String) -> void:
	if text == t:
		return
	text = t
	queue_redraw()


func measured_width() -> float:
	return TTPixelFont.text_width(text, pixel_size)


func _draw() -> void:
	TTPixelFont.draw_text(self, text, Vector2.ZERO, pixel_size, color, align, width)
