//go:build windows

package airplay

import (
	"fmt"
	"log"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// devModeW mirrors the display variant of the Win32 DEVMODEW structure.
type devModeW struct {
	DeviceName         [32]uint16
	SpecVersion        uint16
	DriverVersion      uint16
	Size               uint16
	DriverExtra        uint16
	Fields             uint32
	PositionX          int32
	PositionY          int32
	DisplayOrientation uint32
	DisplayFixedOutput uint32
	Color              int16
	Duplex             int16
	YResolution        int16
	TTOption           int16
	Collate            int16
	FormName           [32]uint16
	LogPixels          uint16
	BitsPerPel         uint32
	PelsWidth          uint32
	PelsHeight         uint32
	DisplayFlags       uint32
	DisplayFrequency   uint32
	ICMMethod          uint32
	ICMIntent          uint32
	MediaType          uint32
	DitherType         uint32
	Reserved1          uint32
	Reserved2          uint32
	PanningWidth       uint32
	PanningHeight      uint32
}

// Compile-time check that devModeW matches sizeof(DEVMODEW).
var _ = [1]struct{}{}[unsafe.Sizeof(devModeW{})-220]

const (
	enumCurrentSettings  = 0xFFFFFFFF
	dmBitsPerPel         = 0x00040000
	dmPelsWidth          = 0x00080000
	dmPelsHeight         = 0x00100000
	dmDisplayFrequency   = 0x00400000
	cdsFullscreen        = 0x00000004
	dispChangeSuccessful = 0

	// displayModeSettleTime lets the desktop finish the mode change before
	// Desktop Duplication attaches to it.
	displayModeSettleTime = 1500 * time.Millisecond
)

var (
	user32                   = windows.NewLazySystemDLL("user32.dll")
	procEnumDisplaySettings  = user32.NewProc("EnumDisplaySettingsW")
	procChangeDisplaySetting = user32.NewProc("ChangeDisplaySettingsExW")
)

func enumDisplaySettings(index uint32) (devModeW, bool) {
	mode := devModeW{Size: uint16(unsafe.Sizeof(devModeW{}))}
	result, _, _ := procEnumDisplaySettings.Call(0, uintptr(index), uintptr(unsafe.Pointer(&mode)))
	return mode, result != 0
}

func toDisplayMode(mode devModeW) displayMode {
	return displayMode{mode.PelsWidth, mode.PelsHeight, mode.BitsPerPel, mode.DisplayFrequency}
}

// MatchDisplayAspect temporarily switches the primary display to a mode with
// the receiver canvas's aspect ratio, so the mirrored picture fills the TV
// without letterboxing, stretching, or cropping. The change is dynamic
// (CDS_FULLSCREEN): the saved display settings are untouched and the returned
// function, or the end of this process, restores them. It returns a nil
// function when no change is needed.
func MatchDisplayAspect(monitorIndex, canvasWidth, canvasHeight int) (func(), error) {
	if monitorIndex >= 0 {
		return nil, fmt.Errorf("only the primary display can be switched to the receiver's aspect ratio")
	}
	if canvasWidth <= 0 || canvasHeight <= 0 {
		return nil, fmt.Errorf("receiver canvas %dx%d is unusable", canvasWidth, canvasHeight)
	}
	current, ok := enumDisplaySettings(enumCurrentSettings)
	if !ok {
		return nil, fmt.Errorf("read the current display mode")
	}
	var modes []displayMode
	for index := uint32(0); ; index++ {
		mode, ok := enumDisplaySettings(index)
		if !ok {
			break
		}
		modes = append(modes, toDisplayMode(mode))
	}
	selected, ok := selectAspectDisplayMode(modes, toDisplayMode(current), uint32(canvasWidth), uint32(canvasHeight))
	if !ok {
		if sameAspect(current.PelsWidth, current.PelsHeight, uint32(canvasWidth), uint32(canvasHeight)) {
			return nil, nil
		}
		return nil, fmt.Errorf("the display offers no %dx%d-shaped mode below %dx%d", canvasWidth, canvasHeight, current.PelsWidth, current.PelsHeight)
	}

	request := devModeW{
		Size:             uint16(unsafe.Sizeof(devModeW{})),
		Fields:           dmPelsWidth | dmPelsHeight | dmBitsPerPel | dmDisplayFrequency,
		PelsWidth:        selected.width,
		PelsHeight:       selected.height,
		BitsPerPel:       selected.bitsPerPixel,
		DisplayFrequency: selected.frequency,
	}
	result, _, _ := procChangeDisplaySetting.Call(0, uintptr(unsafe.Pointer(&request)), 0, cdsFullscreen, 0)
	if int32(result) != dispChangeSuccessful {
		return nil, fmt.Errorf("switch the display to %dx%d: ChangeDisplaySettingsEx returned %d", selected.width, selected.height, int32(result))
	}
	log.Printf("switched this display from %dx%d to %dx%d to match the receiver while mirroring",
		current.PelsWidth, current.PelsHeight, selected.width, selected.height)
	time.Sleep(displayModeSettleTime)

	return func() {
		// A NULL mode restores the display settings saved in the registry.
		result, _, _ := procChangeDisplaySetting.Call(0, 0, 0, 0, 0)
		if int32(result) != dispChangeSuccessful {
			log.Printf("warning: restoring the display mode returned %d", int32(result))
			return
		}
		log.Printf("restored this display to %dx%d", current.PelsWidth, current.PelsHeight)
	}, nil
}
