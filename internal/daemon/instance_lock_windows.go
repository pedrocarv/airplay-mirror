//go:build windows

package daemon

import (
	"fmt"
	"os"
)

func lockInstanceFile(_ *os.File) error {
	return fmt.Errorf("background daemon mode is not supported on Windows")
}

func unlockInstanceFile(_ *os.File) error { return nil }

func isInstanceLockBusy(_ error) bool { return false }
