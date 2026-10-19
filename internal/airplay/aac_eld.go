package airplay

import (
	"encoding/binary"
	"fmt"
	"log"
	"os"
	"runtime"
	"sync"
	"unsafe"
)

// AAC-ELD is the screen-audio codec iPhones use, and some receivers (Sony's
// AirTunes/377.30 among them) accept an ALAC screen stream but play nothing.
// The only practical AAC-ELD encoder is Fraunhofer's libfdk-aac, whose licence
// is not LGPL-compatible. The engine therefore loads it at run time instead of
// linking it: Linux uses the distribution's libfdk-aac, and the Windows package
// ships libfdk-aac-2.dll beside the engine. Without the library the sender
// negotiates ALAC as before.
//
// DOUBLETAKE_FDK_AAC overrides the library path.
const fdkAACLibraryEnvironment = "DOUBLETAKE_FDK_AAC"

// FDK-AAC encoder API values from aacenc_lib.h and FDK_audio.h.
const (
	fdkAACENCOK = 0

	fdkParamAOT           = 0x0100
	fdkParamBitrate       = 0x0101
	fdkParamSampleRate    = 0x0103
	fdkParamSBRMode       = 0x0104
	fdkParamGranuleLength = 0x0105
	fdkParamChannelMode   = 0x0106
	fdkParamChannelOrder  = 0x0107
	fdkParamTransmux      = 0x0300

	fdkAOTERAACELD        = 39
	fdkChannelModeStereo  = 2 // MODE_2
	fdkTransportMP4Raw    = 0 // TT_MP4_RAW
	fdkBufferAudioData    = 0 // IN_AUDIO_DATA
	fdkBufferBitstream    = 3 // OUT_BITSTREAM_DATA
	fdkInfoFrameLengthOff = 16
	fdkInfoStructSize     = 256 // AACENC_InfoStruct is 96 bytes; leave headroom
)

// fdkBufDesc mirrors AACENC_BufDesc on 64-bit Linux and Windows.
type fdkBufDesc struct {
	numBufs           int32
	_                 int32
	bufs              uintptr
	bufferIdentifiers uintptr
	bufSizes          uintptr
	bufElSizes        uintptr
}

// fdkInArgs mirrors AACENC_InArgs.
type fdkInArgs struct {
	numInSamples int32
	numAncBytes  int32
}

// fdkOutArgs mirrors AACENC_OutArgs.
type fdkOutArgs struct {
	numOutBytes  int32
	numInSamples int32
	numAncBytes  int32
	bitResState  int32
}

type fdkLibrary struct {
	path                                 string
	open, setParam, info, encode, closer uintptr
}

var (
	fdkLoadOnce sync.Once
	fdkLoaded   *fdkLibrary
	fdkLoadErr  error
)

func loadFDKAAC() (*fdkLibrary, error) {
	fdkLoadOnce.Do(func() {
		if unsafe.Sizeof(uintptr(0)) != 8 {
			fdkLoadErr = fmt.Errorf("%w: run-time libfdk-aac loading requires a 64-bit build", ErrAACELDUnavailable)
			return
		}
		candidates := fdkAACLibraryCandidates()
		if path := os.Getenv(fdkAACLibraryEnvironment); path != "" {
			candidates = []string{path}
		}
		fdkLoaded, fdkLoadErr = loadFDKAACFrom(candidates)
		if fdkLoadErr == nil {
			dbg("[AUDIO] AAC-ELD encoder: %s", fdkLoaded.path)
		}
	})
	return fdkLoaded, fdkLoadErr
}

func loadFDKAACFrom(candidates []string) (*fdkLibrary, error) {
	var failures []string
	for _, path := range candidates {
		library, err := openFDKAACLibrary(path)
		if err == nil {
			return library, nil
		}
		failures = append(failures, err.Error())
	}
	return nil, fmt.Errorf("%w: libfdk-aac not found (%v); %s", ErrAACELDUnavailable, failures, fdkAACInstallHint)
}

var fdkUnavailableWarning sync.Once

// warnAACELDUnavailable explains, once per process, why a receiver that
// offers AAC-ELD is being sent ALAC.
func warnAACELDUnavailable() {
	fdkUnavailableWarning.Do(func() {
		_, err := loadFDKAAC()
		log.Printf("receiver offers AAC-ELD screen audio, but %v; using ALAC, which some TVs accept but play silently", err)
	})
}

// aacELDEncoderAvailable reports whether libfdk-aac could be loaded.
func aacELDEncoderAvailable() bool {
	_, err := loadFDKAAC()
	return err == nil
}

type eldEncoder struct {
	library  *fdkLibrary
	handle   uintptr
	frameLen int
}

func newELDEncoder() (*eldEncoder, error) {
	library, err := loadFDKAAC()
	if err != nil {
		return nil, err
	}
	e := &eldEncoder{library: library}
	var pinner runtime.Pinner
	defer pinner.Unpin()
	handle := new(uintptr)
	pinner.Pin(handle)
	if result := fdkCall(library.open, uintptr(unsafe.Pointer(handle)), 0, 2); int32(result) != fdkAACENCOK {
		return nil, fmt.Errorf("open AAC-ELD encoder: FDK error %d", int32(result))
	}
	e.handle = *handle

	for _, param := range [...]struct {
		name, value uintptr
		optional    bool
	}{
		{fdkParamAOT, fdkAOTERAACELD, false},
		{fdkParamSampleRate, audioSampleRate, false},
		{fdkParamChannelMode, fdkChannelModeStereo, false},
		{fdkParamChannelOrder, 1, false},
		{fdkParamBitrate, 256000, false},
		{fdkParamTransmux, fdkTransportMP4Raw, false},
		// SBR is already off by default for AAC-ELD, and fdk-aac 2.0.2 (Ubuntu
		// 24.04) rejects setting it explicitly. The frame-length check below
		// rejects any configuration that is not plain 480-sample AAC-ELD.
		{fdkParamSBRMode, 0, true},
		{fdkParamGranuleLength, 480, false},
	} {
		if result := fdkCall(library.setParam, e.handle, param.name, param.value); int32(result) != fdkAACENCOK {
			if param.optional {
				dbg("[AUDIO] AAC-ELD encoder ignored parameter 0x%04x: FDK error %d", param.name, int32(result))
				continue
			}
			e.Close()
			return nil, fmt.Errorf("configure AAC-ELD encoder parameter 0x%04x: FDK error %d", param.name, int32(result))
		}
	}
	// A NULL encode call applies the configuration.
	if result := fdkCall(library.encode, e.handle, 0, 0, 0, 0); int32(result) != fdkAACENCOK {
		e.Close()
		return nil, fmt.Errorf("initialize AAC-ELD encoder: FDK error %d", int32(result))
	}

	info := make([]byte, fdkInfoStructSize)
	pinner.Pin(&info[0])
	if result := fdkCall(library.info, e.handle, uintptr(unsafe.Pointer(&info[0]))); int32(result) != fdkAACENCOK {
		e.Close()
		return nil, fmt.Errorf("read AAC-ELD encoder info: FDK error %d", int32(result))
	}
	frameLen := binary.NativeEndian.Uint32(info[fdkInfoFrameLengthOff:])
	if frameLen != 480 {
		e.Close()
		return nil, fmt.Errorf("AAC-ELD encoder selected %d samples per frame, want 480", frameLen)
	}
	e.frameLen = int(frameLen)
	return e, nil
}

func (e *eldEncoder) Encode(pcm, out []byte) (int, error) {
	wantPCM := e.frameLen * 2 * 2 // samples * stereo * S16LE
	if len(pcm) != wantPCM {
		return 0, fmt.Errorf("AAC-ELD PCM frame is %d bytes, want %d", len(pcm), wantPCM)
	}
	if len(out) == 0 {
		return 0, fmt.Errorf("AAC-ELD output buffer is empty")
	}

	// Everything FDK dereferences lives on the heap and stays pinned for the
	// call; the descriptors hold their addresses as plain integers.
	type call struct {
		inBuf, outBuf       uintptr
		inID, outID         int32
		inSize, outSize     int32
		inElSize, outElSize int32
		inDesc, outDesc     fdkBufDesc
		inArgs              fdkInArgs
		outArgs             fdkOutArgs
	}
	c := new(call)
	var pinner runtime.Pinner
	defer pinner.Unpin()
	pinner.Pin(c)
	pinner.Pin(&pcm[0])
	pinner.Pin(&out[0])

	samples := int32(e.frameLen * 2)
	c.inBuf = uintptr(unsafe.Pointer(&pcm[0]))
	c.outBuf = uintptr(unsafe.Pointer(&out[0]))
	c.inID, c.outID = fdkBufferAudioData, fdkBufferBitstream
	c.inSize, c.outSize = samples*2, int32(len(out))
	c.inElSize, c.outElSize = 2, 1
	c.inDesc = fdkBufDesc{
		numBufs:           1,
		bufs:              uintptr(unsafe.Pointer(&c.inBuf)),
		bufferIdentifiers: uintptr(unsafe.Pointer(&c.inID)),
		bufSizes:          uintptr(unsafe.Pointer(&c.inSize)),
		bufElSizes:        uintptr(unsafe.Pointer(&c.inElSize)),
	}
	c.outDesc = fdkBufDesc{
		numBufs:           1,
		bufs:              uintptr(unsafe.Pointer(&c.outBuf)),
		bufferIdentifiers: uintptr(unsafe.Pointer(&c.outID)),
		bufSizes:          uintptr(unsafe.Pointer(&c.outSize)),
		bufElSizes:        uintptr(unsafe.Pointer(&c.outElSize)),
	}
	c.inArgs.numInSamples = samples

	result := fdkCall(e.library.encode, e.handle,
		uintptr(unsafe.Pointer(&c.inDesc)), uintptr(unsafe.Pointer(&c.outDesc)),
		uintptr(unsafe.Pointer(&c.inArgs)), uintptr(unsafe.Pointer(&c.outArgs)))
	if int32(result) != fdkAACENCOK {
		return 0, fmt.Errorf("encode AAC-ELD: FDK error %d", int32(result))
	}
	encoded := int(c.outArgs.numOutBytes)
	if encoded < 0 || encoded > len(out) {
		return 0, fmt.Errorf("AAC-ELD encoder returned invalid size %d", encoded)
	}
	return encoded, nil
}

func (e *eldEncoder) Close() {
	if e == nil || e.handle == 0 {
		return
	}
	handle := new(uintptr)
	*handle = e.handle
	var pinner runtime.Pinner
	pinner.Pin(handle)
	fdkCall(e.library.closer, uintptr(unsafe.Pointer(handle)))
	pinner.Unpin()
	e.handle = 0
}
