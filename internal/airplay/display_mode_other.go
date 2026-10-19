//go:build !windows

package airplay

import "fmt"

// MatchDisplayAspect is available only on Windows. Wayland and X11 display
// modes belong to the compositor or the user's display settings.
func MatchDisplayAspect(int, int, int) (func(), error) {
	return nil, fmt.Errorf("switching the display mode is supported only on Windows")
}
