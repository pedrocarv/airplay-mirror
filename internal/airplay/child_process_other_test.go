//go:build !linux

package airplay

import (
	"os/exec"
	"testing"
)

func assertGStreamerChildPolicy(t *testing.T, _ *exec.Cmd) {
	t.Helper()
}
