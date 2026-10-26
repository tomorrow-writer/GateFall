## Park-Miller "minimal standard" RNG, identical to the one in
## prototype/battle_core.js simulate(): s = s * 16807 % (2^31 - 1).
## Kept separate from Godot's RandomNumberGenerator so sim runs are
## reproducible and comparable with the prototype.
extends RefCounted

const MODULUS := 2147483647
const MULTIPLIER := 16807

var state: int


func _init(seed_value: int = 1) -> void:
	state = seed_value if seed_value != 0 else 1


## Uniform float in (0, 1).
func next() -> float:
	state = (state * MULTIPLIER) % MODULUS
	return float(state) / float(MODULUS)
