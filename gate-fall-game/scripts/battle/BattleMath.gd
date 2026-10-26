## Deterministic math for BattleSim.
##
## Godot's sin()/cos() call the platform libm (glibc on Linux, Apple libm on
## macOS, MSVC on Windows), which can differ in the last bit. The battle is
## chaotic, so a 1-ulp difference changes who wins. These functions are ports
## of what V8 (the JS engine that ran prototype/battle_core.js) uses:
##   sin/cos -> fdlibm (v8/src/base/ieee754.cc)
##   hypot   -> V8's Math.hypot (normalised Kahan sum)
## Result: the same seed gives the same battle on every OS, and the same
## battle as the JS prototype.
##
## NOTE: the constants are built from their IEEE-754 bit patterns because the
## GDScript parser rounds long decimal literals wrongly (e.g. 1.5707963267341256
## comes out 1 ulp off). Never write long decimal literals in sim code; put
## tunable numbers in data/battle_config.json (Godot's JSON parser is exact).
extends RefCounted

static var INVPIO2: float = _from_words(0x3FE45F30, 0x6DC9C883)
static var PIO2_1: float = _from_words(0x3FF921FB, 0x54400000)
static var PIO2_1T: float = _from_words(0x3DD0B461, 0x1A626331)
static var PIO2_2: float = _from_words(0x3DD0B461, 0x1A600000)
static var PIO2_2T: float = _from_words(0x3BA3198A, 0x2E037073)
static var PIO2_3: float = _from_words(0x3BA3198A, 0x2E000000)
static var PIO2_3T: float = _from_words(0x397B839A, 0x252049C1)

static var C1: float = _from_words(0x3FA55555, 0x5555554C)
static var C2: float = _from_words(0xBF56C16C, 0x16C15177)
static var C3: float = _from_words(0x3EFA01A0, 0x19CB1590)
static var C4: float = _from_words(0xBE927E4F, 0x809C52AD)
static var C5: float = _from_words(0x3E21EE9E, 0xBDB4B1C4)
static var C6: float = _from_words(0xBDA8FAE9, 0xBE8838D4)

static var S1: float = _from_words(0xBFC55555, 0x55555549)
static var S2: float = _from_words(0x3F811111, 0x1110F8A6)
static var S3: float = _from_words(0xBF2A01A0, 0x19C161D5)
static var S4: float = _from_words(0x3EC71DE3, 0x57B1FE7D)
static var S5: float = _from_words(0xBE5AE5E6, 0x8A2B9CEB)
static var S6: float = _from_words(0x3DE5D93A, 0x5ACFD57C)

const NPIO2_HW := [
	0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C,
	0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C,
	0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A,
	0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
	0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB,
	0x404858EB, 0x404921FB,
]


## Same result as JS Math.hypot(a, b) in V8.
static func hypot(a: float, b: float) -> float:
	a = absf(a)
	b = absf(b)
	var m := maxf(a, b)
	if m == 0.0:
		return 0.0
	var sum := 0.0
	var comp := 0.0
	var n := a / m
	var summand := n * n - comp
	var prelim := sum + summand
	comp = (prelim - sum) - summand
	sum = prelim
	n = b / m
	summand = n * n - comp
	prelim = sum + summand
	comp = (prelim - sum) - summand
	sum = prelim
	return sqrt(sum) * m


static func dsin(x: float) -> float:
	var ix := _high_word(x) & 0x7FFFFFFF
	if ix <= 0x3FE921FB:
		return _k_sin(x, 0.0, 0)
	if ix >= 0x7FF00000:
		return x - x
	var y := [0.0, 0.0]
	var n := _rem_pio2(x, y)
	match n & 3:
		0: return _k_sin(y[0], y[1], 1)
		1: return _k_cos(y[0], y[1])
		2: return -_k_sin(y[0], y[1], 1)
		_: return -_k_cos(y[0], y[1])


static func dcos(x: float) -> float:
	var ix := _high_word(x) & 0x7FFFFFFF
	if ix <= 0x3FE921FB:
		return _k_cos(x, 0.0)
	if ix >= 0x7FF00000:
		return x - x
	var y := [0.0, 0.0]
	var n := _rem_pio2(x, y)
	match n & 3:
		0: return _k_cos(y[0], y[1])
		1: return -_k_sin(y[0], y[1], 1)
		2: return -_k_cos(y[0], y[1])
		_: return _k_sin(y[0], y[1], 1)


# --- fdlibm internals -------------------------------------------------------

static func _high_word(x: float) -> int:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_double(0, x)
	return b.decode_s32(4)


static func _from_words(hi: int, lo: int) -> float:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_u32(0, lo)
	b.encode_u32(4, hi)
	return b.decode_double(0)


static func _k_sin(x: float, y: float, iy: int) -> float:
	var ix := _high_word(x) & 0x7FFFFFFF
	if ix < 0x3E400000 and int(x) == 0:
		return x
	var z := x * x
	var v := z * x
	var r := S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)))
	if iy == 0:
		return x + v * (S1 + z * r)
	return x - ((z * (0.5 * y - v * r) - y) - v * S1)


static func _k_cos(x: float, y: float) -> float:
	var ix := _high_word(x) & 0x7FFFFFFF
	if ix < 0x3E400000 and int(x) == 0:
		return 1.0
	var z := x * x
	var r := z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))))
	if ix < 0x3FD33333:
		return 1.0 - (0.5 * z - (z * r - x * y))
	var qx: float
	if ix > 0x3FE90000:
		qx = 0.28125
	else:
		qx = _from_words(ix - 0x00200000, 0)
	var iz := 0.5 * z - qx
	var a := 1.0 - qx
	return a - (iz - (z * r - x * y))


## Writes x mod pi/2 into y[0] + y[1], returns the quadrant.
## Covers |x| <= 2^19 * pi/2 (far beyond any angle the battle uses).
static func _rem_pio2(x: float, y: Array) -> int:
	var hx := _high_word(x)
	var ix := hx & 0x7FFFFFFF
	var z: float
	if ix <= 0x3FE921FB:
		y[0] = x
		y[1] = 0.0
		return 0
	if ix < 0x4002D97C:
		if hx > 0:
			z = x - PIO2_1
			if ix != 0x3FF921FB:
				y[0] = z - PIO2_1T
				y[1] = (z - y[0]) - PIO2_1T
			else:
				z -= PIO2_2
				y[0] = z - PIO2_2T
				y[1] = (z - y[0]) - PIO2_2T
			return 1
		z = x + PIO2_1
		if ix != 0x3FF921FB:
			y[0] = z + PIO2_1T
			y[1] = (z - y[0]) + PIO2_1T
		else:
			z += PIO2_2
			y[0] = z + PIO2_2T
			y[1] = (z - y[0]) + PIO2_2T
		return -1
	assert(ix <= 0x413921FB, "BattleMath: angle too large for medium-range reduction")
	var t := absf(x)
	var n := int(t * INVPIO2 + 0.5)
	var fn := float(n)
	var r := t - fn * PIO2_1
	var w := fn * PIO2_1T
	if n < 32 and ix != NPIO2_HW[n - 1]:
		y[0] = r - w
	else:
		var j := ix >> 20
		y[0] = r - w
		var i := j - ((_high_word(y[0]) >> 20) & 0x7FF)
		if i > 16:
			t = r
			w = fn * PIO2_2
			r = t - w
			w = fn * PIO2_2T - ((t - r) - w)
			y[0] = r - w
			i = j - ((_high_word(y[0]) >> 20) & 0x7FF)
			if i > 49:
				t = r
				w = fn * PIO2_3
				r = t - w
				w = fn * PIO2_3T - ((t - r) - w)
				y[0] = r - w
	y[1] = (r - y[0]) - w
	if hx < 0:
		y[0] = -y[0]
		y[1] = -y[1]
		return -n
	return n
