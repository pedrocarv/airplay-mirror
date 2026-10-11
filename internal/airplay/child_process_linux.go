//go:build linux

package airplay

import (
	"os/exec"
	"runtime"
	"syscall"
)

// startGStreamerCommand starts a capture child whose lifetime cannot outlive
// doubletake. Linux delivers Pdeathsig when the creating OS thread exits, not
// strictly when the whole process exits, so the supervising goroutine keeps
// that thread locked until Wait completes.
func startGStreamerCommand(cmd *exec.Cmd) (<-chan error, error) {
	started := make(chan error, 1)
	waitResult := make(chan error, 1)

	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()

		cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
		err := cmd.Start()
		started <- err
		if err != nil {
			close(waitResult)
			return
		}
		waitResult <- cmd.Wait()
		close(waitResult)
	}()

	if err := <-started; err != nil {
		return nil, err
	}
	return waitResult, nil
}
