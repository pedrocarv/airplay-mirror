//go:build linux || darwin || freebsd

package airplay

import (
	"fmt"

	"github.com/ebitengine/purego"
)

const fdkAACInstallHint = "install your distribution's libfdk-aac package (Arch: libfdk-aac, Debian/Ubuntu: libfdk-aac2 from non-free/multiverse, Fedora: fdk-aac from RPM Fusion)"

func fdkAACLibraryCandidates() []string {
	return []string{"libfdk-aac.so.2", "libfdk-aac.so", "libfdk-aac.2.dylib", "libfdk-aac.dylib"}
}

func openFDKAACLibrary(path string) (*fdkLibrary, error) {
	handle, err := purego.Dlopen(path, purego.RTLD_NOW|purego.RTLD_LOCAL)
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
		address, err := purego.Dlsym(handle, symbol.name)
		if err != nil {
			_ = purego.Dlclose(handle)
			return nil, fmt.Errorf("%s: %s: %v", path, symbol.name, err)
		}
		*symbol.target = address
	}
	return library, nil
}

func fdkCall(fn uintptr, args ...uintptr) uintptr {
	result, _, _ := purego.SyscallN(fn, args...)
	return result
}
