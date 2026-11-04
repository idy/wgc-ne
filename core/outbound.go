package core

import (
	"context"
	"errors"
	"net"
	"net/netip"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/dialer"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
)

type outboundOptions struct {
	Peer     string `json:"peer"`
	Resolver string `json:"resolver,omitempty"`
}
type peerOutbound struct {
	outbound.Adapter
	ctx            context.Context
	session        *Session
	peer, resolver string
}

var _ dialer.PacketDialerWithDestination = (*peerOutbound)(nil)

func (o *peerOutbound) addresses(ctx context.Context, destination M.Socksaddr) ([]M.Socksaddr, error) {
	if !destination.IsValid() || destination.Port == 0 {
		return nil, errors.New("invalid destination")
	}
	if !destination.IsDomain() {
		return []M.Socksaddr{destination}, nil
	}
	manager := service.FromContext[adapter.DNSTransportManager](o.ctx)
	router := service.FromContext[adapter.DNSRouter](o.ctx)
	resolver, found := manager.Transport(o.resolver)
	if !found {
		return nil, errors.New("WGC outbound DNS transport unavailable")
	}
	addresses, err := router.Lookup(ctx, destination.Fqdn, adapter.DNSQueryOptions{Transport: resolver})
	if err != nil {
		return nil, errors.New("WGC outbound DNS lookup failed")
	}
	if len(addresses) == 0 {
		return nil, errors.New("WGC outbound DNS returned no addresses")
	}
	result := make([]M.Socksaddr, len(addresses))
	for index, address := range addresses {
		result[index] = M.Socksaddr{Addr: address, Port: destination.Port}
	}
	return result, nil
}
func (o *peerOutbound) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	addresses, err := o.addresses(ctx, destination)
	if err != nil {
		return nil, err
	}
	for _, address := range addresses {
		conn, err := o.session.DialPeer(ctx, o.peer, network, address.String())
		if err == nil {
			return conn, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	return nil, errors.New("WGC destination unavailable")
}
func (o *peerOutbound) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	conn, _, err := o.ListenPacketWithDestination(ctx, destination)
	return conn, err
}
func (o *peerOutbound) ListenPacketWithDestination(ctx context.Context, destination M.Socksaddr) (net.PacketConn, netip.Addr, error) {
	addresses, err := o.addresses(ctx, destination)
	if err != nil {
		return nil, netip.Addr{}, err
	}
	conn, err := o.session.listenPeer(ctx, o.peer, addresses[0])
	if err != nil {
		return nil, netip.Addr{}, err
	}
	return conn, addresses[0].Addr, nil
}
