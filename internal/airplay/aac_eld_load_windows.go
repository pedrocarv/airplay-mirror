//go:build windows

package airplay

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/windows"
)

const fdkAACDLLName = "libfdk-aac-2.dll"

const fdkAACInstallHint = "keep " + fdkAACDLLName + " next to AirPlay.Engine.exe (extract the complete release ZIP)"

// fdkAACLibraryCandidates loads the DLL only from the engine's own directory,
// never through the DLL search path, so a stray copy elsewhere cannot be
// substituted.
func fdkAACLibraryCandidates() []string {
	executable, err := os.Executable()
	if err != nil {
		return nil
	}
	return []string{filepath.Join(filepath.Dir(executable), fdkAACDLLName)}
}

func openFDKAACLibrary(path string) (*fdkLibrary, error) {
	if !filepath.IsAbs(path) {
		return nil, fmt.Errorf("%s: path must be absolute", path)
	}
	handle, err := windows.LoadLibraryEx(path, 0, windows.LOAD_WITH_ALTERED_SEARCH_PATH)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	library := &fdkLibrary{path: path}
	for _, symbol := range []struct {
		name   string
		target *uintptr
	}{
		{"aacEncOpen", &library.open},
		{"aacEncoder_SetParam", &library.setParam},
		{"aacEncInfo", &library.info},
		{"aacEncEncode", &library.encode},
		{"aacEncClose", &library.closer},
	} {
		address, err := windows.GetProcAddress(handle, symbol.name)
		if err != nil {
			_ = windows.FreeLibrary(handle)
			return nil, fmt.Errorf("%s: %s: %v", path, symbol.name, err)
		}
		*symbol.target = address
	}
	return library, nil
}

func fdkCall(fn uintptr, args ...uintptr) uintptr {
	result, _, _ := syscall.SyscallN(fn, args...)
	return result
}
