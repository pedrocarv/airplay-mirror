package airplay

import "testing"

func TestSelectAspectDisplayModeFillsTheReceiver(t *testing.T) {
	// A 3:2 3000x2000 laptop panel mirrored to a 1920x1080 TV.
	current := displayMode{3000, 2000, 32, 60}
	modes := []displayMode{
		{3000, 2000, 32, 60}, {2560, 1440, 32, 60}, {1920, 1080, 32, 48},
		{1920, 1080, 32, 60}, {1920, 1080, 16, 60}, {1680, 1050, 32, 60},
		{1600, 900, 32, 60}, {1366, 768, 32, 60}, {1280, 720, 32, 60},
		{3840, 2160, 32, 60},
	}
	got, ok := selectAspectDisplayMode(modes, current, 1920, 1080)
	if !ok || got != (displayMode{1920, 1080, 32, 60}) {
		t.Fatalf("selected %+v, %t; want 1920x1080 32bpp 60 Hz", got, ok)
	}

	// A 4K canvas uses the largest 16:9 mode the panel offers, never above native.
	got, ok = selectAspectDisplayMode(modes, current, 3840, 2160)
	if !ok || got != (displayMode{2560, 1440, 32, 60}) {
		t.Fatalf("4K canvas selected %+v, %t; want 2560x1440", got, ok)
	}

	// The current refresh rate wins over a closer size at another rate.
	got, ok = selectAspectDisplayMode([]displayMode{{1920, 1080, 32, 48}, {1600, 900, 32, 60}}, current, 1920, 1080)
	if !ok || got != (displayMode{1600, 900, 32, 60}) {
		t.Fatalf("refresh-rate preference selected %+v, %t", got, ok)
	}
}

func TestSelectAspectDisplayModeLeavesMatchingOrUnsupportedDisplays(t *testing.T) {
	if _, ok := selectAspectDisplayMode([]displayMode{{1280, 720, 32, 60}}, displayMode{1920, 1080, 32, 60}, 1920, 1080); ok {
		t.Fatal("a 16:9 display was switched for a 16:9 receiver")
	}
	if _, ok := selectAspectDisplayMode([]displayMode{{1920, 1200, 32, 60}, {1280, 800, 32, 60}}, displayMode{1920, 1200, 32, 60}, 1920, 1080); ok {
		t.Fatal("a display without 16:9 modes reported a selection")
	}
}

func TestSameAspectToleratesNominalSixteenNine(t *testing.T) {
	if !sameAspect(1366, 768, 1920, 1080) {
		t.Error("1366x768 should count as 16:9")
	}
	if sameAspect(1920, 1200, 1920, 1080) {
		t.Error("16:10 should not count as 16:9")
	}
}
