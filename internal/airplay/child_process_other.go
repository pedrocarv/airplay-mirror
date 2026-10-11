//go:build !linux

package airplay

import "os/exec"

// Non-Linux platforms rely on CommandContext to stop GStreamer when the
// capture context is cancelled. Wait remains asynchronous so callers can
// monitor the pipeline without blocking frame delivery.
func startGStreamerCommand(cmd *exec.Cmd) (<-chan error, error) {
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	waitResult := make(chan error, 1)
	go func() {
		waitResult <- cmd.Wait()
		close(waitResult)
	}()
	return waitResult, nil
}
