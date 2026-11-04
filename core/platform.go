package core

import (
	"context"
	"net"
	"net/netip"
	"os"
	"sync"

	"github.com/idy/wgc-ne/core/transport"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/logger"
)

var _ adapter.PlatformInterface = (*suppliedTUNPlatform)(nil)

type suppliedTUNPlatform struct {
	mu      sync.Mutex
	fd      int
	android bool
	ctx     context.Context
}

func (p *suppliedTUNPlatform) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	CloseOwnedFD(p.fd)
	p.fd = -1
}

func (p *suppliedTUNPlatform) duplicate() (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.fd < 0 {
		return -1, net.ErrClosed
	}
	return duplicateFD(p.fd)
}

func (*suppliedTUNPlatform) Initialize(adapter.NetworkManager) error       { return nil }
func (p *suppliedTUNPlatform) UsePlatformAutoDetectInterfaceControl() bool { return p.android }
func (p *suppliedTUNPlatform) AutoDetectInterfaceControl(fd int) error {
	if !p.android {
		return os.ErrInvalid
	}
	return transport.ProtectSocket(p.ctx, fd)
}
func (*suppliedTUNPlatform) UsePlatformInterface() bool { return true }
func (p *suppliedTUNPlatform) OpenInterface(options *tun.Options, _ option.TunPlatformOptions) (tun.Tun, error) {
	fd, err := p.duplicate()
	if err != nil {
		return nil, err
	}
	if p.android {
		// VpnService supplies a Linux TUN with no packet-info prefix. Ensure
		// reads can be interrupted during shutdown even if the host used
		// Builder.setBlocking(true). A duplicate shares these status flags.
		if err := nonblockingFD(fd); err != nil {
			CloseOwnedFD(fd)
			return nil, err
		}
	}
	options.FileDescriptor = fd
	options.EXP_ExternalConfiguration = true
	device, err := tun.New(*options)
	if err != nil {
		CloseOwnedFD(fd)
		return nil, err
	}
	name, err := device.Name()
	if err != nil {
		_ = device.Close()
		return nil, err
	}
	options.Name = name
	return device, nil
}
func (*suppliedTUNPlatform) ProcessPlatformOptions(option.TunPlatformOptions) error { return nil }

// Android protection follows the OS default underlying network. Do not open an
// unprivileged netlink monitor; no explicit network selection is implemented.
func (p *suppliedTUNPlatform) UsePlatformDefaultInterfaceMonitor() bool { return p.android }
func (*suppliedTUNPlatform) CreateDefaultInterfaceMonitor(logger.Logger) tun.DefaultInterfaceMonitor {
	return nil
}
func (*suppliedTUNPlatform) UsePlatformNetworkInterfaces() bool { return false }
func (*suppliedTUNPlatform) NetworkInterfaces() ([]adapter.NetworkInterface, error) {
	return nil, os.ErrInvalid
}
func (p *suppliedTUNPlatform) UnderNetworkExtension() bool            { return !p.android }
func (*suppliedTUNPlatform) NetworkExtensionIncludeAllNetworks() bool { return false }
func (*suppliedTUNPlatform) ClearDNSCache()                           {}
func (*suppliedTUNPlatform) RequestPermissionForWIFIState() error     { return os.ErrPermission }
func (*suppliedTUNPlatform) ReadWIFIState(context.Context) adapter.WIFIState {
	return adapter.WIFIState{}
}
func (*suppliedTUNPlatform) UsePlatformConnectionOwnerFinder() bool { return false }
func (*suppliedTUNPlatform) FindConnectionOwner(*adapter.FindConnectionOwnerRequest) (*adapter.ConnectionOwner, error) {
	return nil, os.ErrPermission
}
func (*suppliedTUNPlatform) UsePlatformWIFIMonitor() bool                 { return false }
func (*suppliedTUNPlatform) UsePlatformNotification() bool                { return false }
func (*suppliedTUNPlatform) SendNotification(*adapter.Notification) error { return os.ErrInvalid }
func (*suppliedTUNPlatform) CancelNotification(string, int32) error       { return os.ErrInvalid }
func (*suppliedTUNPlatform) MyInterfaceAddress() []netip.Addr             { return nil }
func (*suppliedTUNPlatform) UsePlatformNeighborResolver() bool            { return false }
func (*suppliedTUNPlatform) StartNeighborMonitor(adapter.NeighborUpdateListener) error {
	return os.ErrInvalid
}
func (*suppliedTUNPlatform) CloseNeighborMonitor(adapter.NeighborUpdateListener) error {
	return os.ErrInvalid
}
func (*suppliedTUNPlatform) UsePlatformShell() bool    { return false }
func (*suppliedTUNPlatform) CheckPlatformShell() error { return os.ErrPermission }
func (*suppliedTUNPlatform) OpenShellSession(*adapter.PlatformUser, string, []string, string, int32, int32) (adapter.ShellSession, error) {
	return nil, os.ErrPermission
}
func (*suppliedTUNPlatform) LookupUser(string) (*adapter.PlatformUser, error) {
	return nil, os.ErrPermission
}
func (*suppliedTUNPlatform) LookupSFTPServer() (string, error)     { return "", os.ErrPermission }
func (*suppliedTUNPlatform) ReadSystemSSHHostKey() ([]byte, error) { return nil, os.ErrPermission }
func (*suppliedTUNPlatform) TailscaleHostname() string             { return "" }
func (*suppliedTUNPlatform) UsePlatformBridge() bool               { return false }
func (*suppliedTUNPlatform) CreateBridge(adapter.BridgeOptions) (adapter.BridgeSession, error) {
	return nil, os.ErrPermission
}
