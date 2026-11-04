//go:build unix && with_gvisor

package core

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"sync"
	"testing"

	"github.com/idy/wgc-ne/core/transport"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	singTun "github.com/sagernet/sing-tun"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
	"golang.org/x/sys/unix"
)

func TestSingBoxDirectSocketsAlwaysProtect(t *testing.T) {
	for _, bind := range []bool{false, true} {
		for _, reject := range []bool{false, true} {
			name := map[bool]string{false: "default", true: "explicit-bind"}[bind] + "/" + map[bool]string{false: "success", true: "failure"}[reject]
			t.Run(name, func(t *testing.T) {
				var mu sync.Mutex
				var fds []int
				ctx := transport.WithSocketProtector(context.Background(), func(fd int) error {
					mu.Lock()
					fds = append(fds, fd)
					mu.Unlock()
					address, err := unix.Getsockname(fd)
					if err != nil {
						return err
					}
					if address.(*unix.SockaddrInet4).Port != 0 {
						t.Error("direct socket bound/connected before protection")
					}
					if reject {
						return errors.New("host-private-error")
					}
					return nil
				})
				config, err := NormalizeConfig(testConfig(t))
				if err != nil {
					t.Fatal(err)
				}
				raw, _ := defaultBoxConfig(config)
				var document map[string]any
				if err := json.Unmarshal(raw, &document); err != nil {
					t.Fatal(err)
				}
				direct := map[string]any{"type": "direct", "tag": "bypass"}
				if bind {
					direct["inet4_bind_address"] = "127.0.0.1"
				}
				document["outbounds"] = append(document["outbounds"].([]any), direct)
				// Retain the default auto_detect_interface=false. This bypassed
				// PlatformInterface protection in the pinned upstream dialer.
				config.SingBox, _ = json.Marshal(document)
				boxCtx := boxContext(ctx, config, nil)
				options, err := parseBoxConfig(boxCtx, config)
				if err != nil {
					t.Fatal(err)
				}
				instance, err := box.New(box.Options{Context: boxCtx, Options: options})
				if err != nil {
					t.Fatal(err)
				}
				defer instance.Close()
				outbound, found := instance.Outbound().Outbound("bypass")
				if !found {
					t.Fatal("direct outbound missing")
				}
				// No Box.Start: only loopback test sockets run, never a real TUN,
				// route installation, interface monitor, or host DNS lookup.
				tcp, err := net.Listen("tcp4", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				defer tcp.Close()
				for _, network := range []string{"tcp", "udp", "udp-listener"} {
					mu.Lock()
					before := len(fds)
					mu.Unlock()
					var conn interface{ Close() error }
					var err error
					if network == "udp-listener" {
						conn, err = outbound.ListenPacket(ctx, M.ParseSocksaddr("127.0.0.1:9"))
					} else {
						conn, err = outbound.DialContext(ctx, network, M.ParseSocksaddr(tcp.Addr().String()))
					}
					mu.Lock()
					opened := append([]int(nil), fds[before:]...)
					mu.Unlock()
					if len(opened) == 0 {
						t.Fatalf("%s skipped protection", network)
					}
					if reject {
						if err == nil {
							_ = conn.Close()
							t.Fatalf("%s continued after rejected protection", network)
						}
					} else {
						if err != nil {
							t.Fatalf("%s failed after protection: %v", network, err)
						}
						_ = conn.Close()
					}
					for _, fd := range opened {
						if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != unix.EBADF {
							t.Fatalf("%s socket leaked after close/failure: %v", network, err)
						}
					}
				}
				// Box registers its real manager after constructing the context;
				// registry cloning must retain the protection decorator too.
				cloned := service.ExtendContext(boxCtx)
				if _, ok := service.FromContext[adapter.NetworkManager](cloned).(*protectedNetworkManager); !ok {
					t.Fatal("cloned services lost socket protection")
				}
			})
		}
	}
}

func TestAndroidRequiresProtectorAndConsumesSuppliedFD(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	owned, err := duplicateFD(int(reader.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	engine, err := openForPlatform(context.Background(), owned, testConfig(t), SessionOptions{}, "android")
	if engine != nil || !errors.Is(err, transport.ErrSocketProtectorRequired) {
		t.Fatalf("Android accepted missing protection: %v", err)
	}
	if _, err := unix.FcntlInt(uintptr(owned), unix.F_GETFD, 0); err != unix.EBADF {
		t.Fatalf("rejected Android start leaked owned fd: %v", err)
	}
	if _, err := unix.FcntlInt(reader.Fd(), unix.F_GETFD, 0); err != nil {
		t.Fatalf("rejected Android start closed the host fd: %v", err)
	}
}

func TestSuppliedTUNOpenFailureClosesOnlyItsDuplicate(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	owned, err := duplicateFD(int(reader.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	platform := &suppliedTUNPlatform{fd: owned, android: true}
	defer platform.Close()
	options := singTun.Options{MTU: 1280}
	// A pipe is never a TUN. The real constructor or Name ioctl must reject it
	// without touching host networking, and only the new duplicate is closed.
	device, err := platform.OpenInterface(&options, option.TunPlatformOptions{})
	if device != nil || err == nil {
		if device != nil {
			_ = device.Close()
		}
		t.Fatal("a non-TUN descriptor was accepted")
	}
	if options.FileDescriptor == owned || options.FileDescriptor < 3 || !options.EXP_ExternalConfiguration {
		t.Fatal("TUN construction did not isolate the external descriptor")
	}
	if _, err := unix.FcntlInt(uintptr(options.FileDescriptor), unix.F_GETFD, 0); err != unix.EBADF {
		t.Fatalf("failed TUN construction leaked its duplicate: %v", err)
	}
	for _, fd := range []int{owned, int(reader.Fd())} {
		if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != nil {
			t.Fatalf("TUN construction closed another owner's fd: %v", err)
		}
	}
}

func TestSuppliedTUNOwnershipAndClosedFDReuse(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	owned, err := duplicateFD(int(reader.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	platform := &suppliedTUNPlatform{fd: owned, android: true}
	dup, err := platform.duplicate()
	if err != nil {
		t.Fatal(err)
	}
	defer CloseOwnedFD(dup)
	if dup < 3 || dup == owned {
		t.Fatal("TUN duplicate must be a distinct non-stdio fd")
	}
	flags, err := unix.FcntlInt(uintptr(dup), unix.F_GETFD, 0)
	if err != nil || flags&unix.FD_CLOEXEC == 0 {
		t.Fatalf("TUN duplicate lacks CLOEXEC: %v", err)
	}
	platform.Close()
	platform.Close()
	if _, err := unix.FcntlInt(uintptr(dup), unix.F_GETFD, 0); err != nil {
		t.Fatalf("platform closed sing-box's independent duplicate: %v", err)
	}
	if _, err := platform.duplicate(); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("closed platform duplicated a potentially reused fd: %v", err)
	}
	if platform.UnderNetworkExtension() || !platform.UsePlatformAutoDetectInterfaceControl() || !platform.UsePlatformDefaultInterfaceMonitor() {
		t.Fatal("Android platform incorrectly advertises Apple/monitor behavior")
	}
	apple := &suppliedTUNPlatform{}
	if !apple.UnderNetworkExtension() || apple.UsePlatformAutoDetectInterfaceControl() || apple.UsePlatformDefaultInterfaceMonitor() {
		t.Fatal("Apple platform behavior changed")
	}
}
