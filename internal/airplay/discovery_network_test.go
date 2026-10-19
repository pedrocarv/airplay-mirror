package airplay

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/libp2p/zeroconf/v2"
)

// TestDiscoverAirPlayDevicesOverMulticast advertises a receiver on this host
// and browses for it through the real mDNS sockets. It touches the local
// network, so it runs only when DOUBLETAKE_MDNS_NETWORK_TEST=1.
func TestDiscoverAirPlayDevicesOverMulticast(t *testing.T) {
	if os.Getenv("DOUBLETAKE_MDNS_NETWORK_TEST") != "1" {
		t.Skip("set DOUBLETAKE_MDNS_NETWORK_TEST=1 to browse the local network")
	}
	ifaces, _, err := airPlayMDNSInterfaces()
	if err != nil {
		t.Fatalf("mDNS interfaces: %v", err)
	}
	if len(ifaces) == 0 {
		t.Fatal("no multicast-capable LAN interface")
	}

	const instance = "Doubletake CI Receiver"
	server, err := zeroconf.Register(instance, "_airplay._tcp", "local.", 7123,
		[]string{"model=DoubletakeCI1,1", "deviceid=02:00:00:00:00:01"}, ifaces)
	if err != nil {
		t.Fatalf("register test receiver: %v", err)
	}
	defer server.Shutdown()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	devices, err := DiscoverAirPlayDevices(ctx)
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	for _, device := range devices {
		if device.Name == instance {
			if device.Port != 7123 || device.Model != "DoubletakeCI1,1" || device.IP == "" {
				t.Fatalf("test receiver resolved incorrectly: %+v", device)
			}
			return
		}
	}
	t.Fatalf("test receiver %q not discovered; found %d other receiver(s)", instance, len(devices))
}
