@tool
extends EditorPlugin
## Registers the export-time authoring stripper. No UI, no docks — the kit's
## editor surface is the AuthoringRoot Bake button; this plugin only exists
## because EditorExportPlugins must be added by an EditorPlugin.

const StripExport := preload("res://addons/carlito_kit/strip_export.gd")

var _strip: EditorExportPlugin


func _enter_tree() -> void:
	_strip = StripExport.new()
	add_export_plugin(_strip)


func _exit_tree() -> void:
	remove_export_plugin(_strip)
	_strip = null
