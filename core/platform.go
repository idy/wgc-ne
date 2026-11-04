package core

import (
	"context"
	"net/netip"
	"os"
	"sync"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/logger"
)

var _ adapter.PlatformInterface = (*applePlatform)(nil)

type applePlatform struct {
	fd   int
	once sync.Once
}

func (p *applePlatform) Close()                                    { p.once.Do(func() { CloseOwnedFD(p.fd) }) }
func (*applePlatform) Initialize(adapter.NetworkManager) error     { return nil }
func (*applePlatform) UsePlatformAutoDetectInterfaceControl() bool { return false }
func (*applePlatform) AutoDetectInterfaceControl(int) error        { return os.ErrInvalid }
func (*applePlatform) UsePlatformInterface() bool                  { return true }
func (p *applePlatform) OpenInterface(options *tun.Options, _ option.TunPlatformOptions) (tun.Tun, error) {
	fd, err := duplicateFD(p.fd)
	if err != nil {
		return nil, err
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
func (*applePlatform) ProcessPlatformOptions(option.TunPlatformOptions) error { return nil }
func (*applePlatform) UsePlatformDefaultInterfaceMonitor() bool               { return false }
func (*applePlatform) CreateDefaultInterfaceMonitor(logger.Logger) tun.DefaultInterfaceMonitor {
	return nil
}
func (*applePlatform) UsePlatformNetworkInterfaces() bool { return false }
func (*applePlatform) NetworkInterfaces() ([]adapter.NetworkInterface, error) {
	return nil, os.ErrInvalid
}
func (*applePlatform) UnderNetworkExtension() bool                     { return true }
func (*applePlatform) NetworkExtensionIncludeAllNetworks() bool        { return false }
func (*applePlatform) ClearDNSCache()                                  {}
func (*applePlatform) RequestPermissionForWIFIState() error            { return os.ErrPermission }
func (*applePlatform) ReadWIFIState(context.Context) adapter.WIFIState { return adapter.WIFIState{} }
func (*applePlatform) UsePlatformConnectionOwnerFinder() bool          { return false }
func (*applePlatform) FindConnectionOwner(*adapter.FindConnectionOwnerRequest) (*adapter.ConnectionOwner, error) {
	return nil, os.ErrPermission
}
func (*applePlatform) UsePlatformWIFIMonitor() bool                 { return false }
func (*applePlatform) UsePlatformNotification() bool                { return false }
func (*applePlatform) SendNotification(*adapter.Notification) error { return os.ErrInvalid }
func (*applePlatform) CancelNotification(string, int32) error       { return os.ErrInvalid }
func (*applePlatform) MyInterfaceAddress() []netip.Addr             { return nil }
func (*applePlatform) UsePlatformNeighborResolver() bool            { return false }
func (*applePlatform) StartNeighborMonitor(adapter.NeighborUpdateListener) error {
	return os.ErrInvalid
}
func (*applePlatform) CloseNeighborMonitor(adapter.NeighborUpdateListener) error {
	return os.ErrInvalid
}
func (*applePlatform) UsePlatformShell() bool    { return false }
func (*applePlatform) CheckPlatformShell() error { return os.ErrPermission }
func (*applePlatform) OpenShellSession(*adapter.PlatformUser, string, []string, string, int32, int32) (adapter.ShellSession, error) {
	return nil, os.ErrPermission
}
func (*applePlatform) LookupUser(string) (*adapter.PlatformUser, error) { return nil, os.ErrPermission }
func (*applePlatform) LookupSFTPServer() (string, error)                { return "", os.ErrPermission }
func (*applePlatform) ReadSystemSSHHostKey() ([]byte, error)            { return nil, os.ErrPermission }
func (*applePlatform) TailscaleHostname() string                        { return "" }
func (*applePlatform) UsePlatformBridge() bool                          { return false }
func (*applePlatform) CreateBridge(adapter.BridgeOptions) (adapter.BridgeSession, error) {
	return nil, os.ErrPermission
}
