//go:build !linux && !darwin && !freebsd && !windows

package airplay

import "fmt"

const fdkAACInstallHint = "run-time libfdk-aac loading is not supported on this platform"

func fdkAACLibraryCandidates() []string { return nil }

func openFDKAACLibrary(path string) (*fdkLibrary, error) {
	return nil, fmt.Errorf("%s: unsupported platform", path)
}

func fdkCall(uintptr, ...uintptr) uintptr { return 0 }
