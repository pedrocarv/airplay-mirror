package airplay

// displayMode is one resolution a monitor offers.
type displayMode struct {
	width, height, bitsPerPixel, frequency uint32
}

// sameAspect reports whether two sizes have the same aspect ratio within
// 0.5%, which absorbs modes such as 1366x768 that are nominally 16:9.
func sameAspect(width, height, otherWidth, otherHeight uint32) bool {
	if width == 0 || height == 0 || otherWidth == 0 || otherHeight == 0 {
		return false
	}
	left := uint64(width) * uint64(otherHeight)
	right := uint64(otherWidth) * uint64(height)
	difference := left - right
	if right > left {
		difference = right - left
	}
	return difference*200 <= left
}

// selectAspectDisplayMode picks the monitor mode that lets the receiver
// canvas be filled without letterboxing, scaling, or cropping: the canvas's
// aspect ratio at the size closest to the canvas, never above the current
// (native) resolution, keeping the current colour depth and preferring the
// current refresh rate. It reports false when the current mode already
// matches or no suitable mode exists.
func selectAspectDisplayMode(modes []displayMode, current displayMode, canvasWidth, canvasHeight uint32) (displayMode, bool) {
	if sameAspect(current.width, current.height, canvasWidth, canvasHeight) {
		return displayMode{}, false
	}
	distance := func(mode displayMode) uint32 {
		if mode.width > canvasWidth {
			return mode.width - canvasWidth
		}
		return canvasWidth - mode.width
	}
	// better orders candidates by current refresh rate, then closeness to the
	// canvas, then the larger size, then the higher refresh rate.
	better := func(mode, than displayMode) bool {
		if keeps, keptBest := mode.frequency == current.frequency, than.frequency == current.frequency; keeps != keptBest {
			return keeps
		}
		if distance(mode) != distance(than) {
			return distance(mode) < distance(than)
		}
		if mode.width != than.width {
			return mode.width > than.width
		}
		return mode.frequency > than.frequency
	}
	var best displayMode
	found := false
	for _, mode := range modes {
		if mode.bitsPerPixel != current.bitsPerPixel ||
			mode.width > current.width || mode.height > current.height ||
			!sameAspect(mode.width, mode.height, canvasWidth, canvasHeight) {
			continue
		}
		if !found || better(mode, best) {
			best, found = mode, true
		}
	}
	return best, found
}
