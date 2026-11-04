package core

import (
	"context"
	"encoding/json"
	"errors"
	"net/netip"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/certificate"
	"github.com/sagernet/sing-box/adapter/endpoint"
	"github.com/sagernet/sing-box/adapter/inbound"
	"github.com/sagernet/sing-box/adapter/outbound"
	adapterService "github.com/sagernet/sing-box/adapter/service"
	"github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/dns/transport"
	"github.com/sagernet/sing-box/dns/transport/fakeip"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/direct"
	"github.com/sagernet/sing-box/protocol/tun"
	singJSON "github.com/sagernet/sing/common/json"
)

func boxContext(ctx context.Context, config Config, session *Session) context.Context {
	inputs, outputs := inbound.NewRegistry(), outbound.NewRegistry()
	tun.RegisterInbound(inputs)
	direct.RegisterOutbound(outputs)
	outbound.Register[outboundOptions](outputs, "wgc", func(ctx context.Context, _ adapter.Router, _ log.ContextLogger, tag string, options outboundOptions) (adapter.Outbound, error) {
		found := false
		for _, peer := range config.Peers {
			if peer.ID == options.Peer {
				found = true
				break
			}
		}
		if !found {
			return nil, errors.New("WGC outbound references an undeclared peer")
		}
		if options.Resolver == "" {
			options.Resolver = "dns-remote"
		}
		return &peerOutbound{Adapter: outbound.NewAdapter("wgc", tag, []string{"tcp", "udp"}, nil), ctx: ctx, session: session, peer: options.Peer, resolver: options.Resolver}, nil
	})
	resolvers := dns.NewTransportRegistry()
	transport.RegisterUDP(resolvers)
	transport.RegisterTCP(resolvers)
	fakeip.RegisterTransport(resolvers)
	return box.Context(ctx, inputs, outputs, endpoint.NewRegistry(), resolvers, adapterService.NewRegistry(), certificate.NewRegistry())
}

type object = map[string]any

func defaultBoxConfig(config Config) ([]byte, error) {
	dnsServer, _ := netip.ParseAddrPort(config.DNSServer)
	return json.Marshal(object{
		"log":       object{"disabled": true},
		"inbounds":  []object{{"type": "tun", "tag": "tun-in", "address": config.Addresses, "mtu": config.MTU, "stack": "mixed", "auto_route": false, "dns_mode": "disabled"}},
		"outbounds": []object{{"type": "wgc", "tag": "vpn", "peer": config.DefaultPeer, "resolver": "dns-remote"}},
		"dns":       object{"servers": []object{{"type": "udp", "tag": "dns-remote", "server": dnsServer.Addr().String(), "server_port": dnsServer.Port(), "detour": "vpn"}}, "final": "dns-remote", "reverse_mapping": true},
		"route":     object{"rules": []object{{"inbound": []string{"tun-in"}, "port": []int{53}, "action": "hijack-dns"}}, "final": "vpn", "auto_detect_interface": false, "default_domain_resolver": "dns-remote"},
	})
}

func parseBoxConfig(ctx context.Context, config Config) (option.Options, error) {
	data := config.SingBox
	if len(data) == 0 {
		var err error
		data, err = defaultBoxConfig(config)
		if err != nil {
			return option.Options{}, err
		}
	}
	var options option.Options
	if err := singJSON.UnmarshalContext(ctx, data, &options); err != nil {
		return options, errors.New("invalid sing-box configuration")
	}
	var tunCount int
	for _, input := range options.Inbounds {
		if input.Type != "tun" {
			return options, errors.New("only a TUN inbound is supported")
		}
		tunCount++
		value, ok := input.Options.(*option.TunInboundOptions)
		if !ok {
			return options, errors.New("invalid TUN configuration")
		}
		if value.AutoRoute || value.AutoRedirect {
			return options, errors.New("NetworkExtension owns route installation")
		}
		if value.MTU != config.MTU || len(value.Address) != len(config.Addresses) {
			return options, errors.New("TUN addresses and MTU must match network settings")
		}
		for index, prefix := range value.Address {
			if prefix.String() != config.Addresses[index] {
				return options, errors.New("TUN addresses must match network settings")
			}
		}
	}
	if tunCount != 1 {
		return options, errors.New("exactly one TUN inbound is required")
	}
	// Native callers must never receive logging of secrets from arbitrary
	// sing-box configuration. Diagnostics use redacted SDK status/errors.
	options.Log = &option.LogOptions{Disabled: true}
	return options, nil
}

// Validate performs parsing and factory registration checks without opening a
// socket, creating an OS TUN, or changing host configuration.
func Validate(config Config) (NetworkSettings, error) {
	config, err := NormalizeConfig(config)
	if err != nil {
		return NetworkSettings{}, err
	}
	if err := transportRegistryValidate(config); err != nil {
		return NetworkSettings{}, err
	}
	ctx := boxContext(context.Background(), config, nil)
	options, err := parseBoxConfig(ctx, config)
	if err != nil {
		return NetworkSettings{}, err
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		return NetworkSettings{}, errors.New("sing-box configuration initialization failed")
	}
	_ = instance.Close()
	return config.NetworkSettings(), nil
}
