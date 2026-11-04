//go:build with_gvisor

package core

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"reflect"
	"testing"

	"github.com/idy/wgc-ne/core/transport"
	"github.com/sagernet/gvisor/pkg/tcpip/stack"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/route/rule"
	singTun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/service"
)

func testCustomBoxTUN(t *testing.T, config Config, change func(map[string]any)) Config {
	t.Helper()
	return testCustomBox(t, config, func(document map[string]any) {
		change(document["inbounds"].([]any)[0].(map[string]any))
	})
}

func testCustomBox(t *testing.T, config Config, change func(map[string]any)) Config {
	t.Helper()
	config, err := NormalizeConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := defaultBoxConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatal(err)
	}
	change(document)
	config.SingBox, err = json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	return config
}

// The pinned NewStack constructors allocate only their configuration structs;
// all TUN I/O, stack workers, listeners, and OS routing require Start. Every
// fake method panics so these tests cannot accidentally cross that boundary.
type boxConstructorTun struct{}

var _ singTun.GVisorTun = (*boxConstructorTun)(nil)

func (*boxConstructorTun) Name() (string, error)     { panic("unexpected TUN I/O") }
func (*boxConstructorTun) Read([]byte) (int, error)  { panic("unexpected TUN I/O") }
func (*boxConstructorTun) Write([]byte) (int, error) { panic("unexpected TUN I/O") }
func (*boxConstructorTun) Start() error              { panic("unexpected TUN I/O") }
func (*boxConstructorTun) Close() error              { panic("unexpected TUN I/O") }
func (*boxConstructorTun) UpdateRouteOptions(singTun.Options) error {
	panic("unexpected OS route update")
}
func (*boxConstructorTun) WritePacket(*stack.PacketBuffer) (int, error) {
	panic("unexpected TUN I/O")
}
func (*boxConstructorTun) NewEndpoint() (stack.LinkEndpoint, stack.NICOptions, error) {
	panic("unexpected stack start")
}

func boxConstructorOptions(addresses []string) singTun.StackOptions {
	options := singTun.StackOptions{
		Context:    context.Background(),
		Tun:        &boxConstructorTun{},
		TunOptions: singTun.Options{MTU: 1280},
	}
	for _, value := range addresses {
		prefix := netip.MustParsePrefix(value)
		if prefix.Addr().Is4() {
			options.TunOptions.Inet4Address = append(options.TunOptions.Inet4Address, prefix)
		} else {
			options.TunOptions.Inet6Address = append(options.TunOptions.Inet6Address, prefix)
		}
	}
	return options
}

func TestDefaultBoxHostPrefixesUseGVisor(t *testing.T) {
	for _, addresses := range [][]string{
		{"10.7.0.2/32"},
		{"fd00:7::2/128"},
		{"10.7.0.2/32", "fd00:7::2/128"},
	} {
		t.Run(addresses[0], func(t *testing.T) {
			config := testConfig(t)
			config.Addresses = addresses
			config, err := NormalizeConfig(config)
			if err != nil {
				t.Fatal(err)
			}
			settings, err := Validate(config)
			if err != nil {
				t.Fatalf("documented host prefixes rejected: %v", err)
			}
			if !reflect.DeepEqual(settings.Addresses, addresses) {
				t.Fatal("host prefixes changed")
			}
			options, err := parseBoxConfig(boxContext(context.Background(), config, nil), config)
			if err != nil {
				t.Fatal(err)
			}
			inbound := options.Inbounds[0].Options.(*option.TunInboundOptions)
			if inbound.Stack != "gvisor" {
				t.Fatalf("default stack = %q, want gvisor", inbound.Stack)
			}
			actual, err := singTun.NewStack(inbound.Stack, boxConstructorOptions(addresses))
			if err != nil {
				t.Fatalf("real TUN stack constructor rejected default: %v", err)
			}
			if _, ok := actual.(*singTun.GVisor); !ok {
				t.Fatalf("default constructed %T, want *tun.GVisor", actual)
			}
		})
	}
}

func TestCustomBoxStackPrefixesMatchRealConstructors(t *testing.T) {
	prefixCases := []struct {
		name      string
		addresses []string
		systemOK  bool
	}{
		{"IPv4 host", []string{"10.7.0.2/32"}, false},
		{"IPv6 host", []string{"fd00:7::2/128"}, false},
		{"dual hosts", []string{"10.7.0.2/32", "fd00:7::2/128"}, false},
		{"IPv4 lower 31", []string{"10.7.0.2/31"}, true},
		{"IPv4 final 31", []string{"10.7.0.3/31"}, false},
		{"IPv6 lower 127", []string{"fd00:7::2/127"}, true},
		{"IPv6 final 127", []string{"fd00:7::3/127"}, false},
		{"IPv4 interior host bits", []string{"10.7.0.2/24"}, true},
		{"IPv4 final 24", []string{"10.7.0.255/24"}, false},
		{"IPv6 interior host bits", []string{"fd00:7::1/126"}, true},
		{"IPv6 final 126", []string{"fd00:7::3/126"}, false},
		{"later IPv4 cannot rescue first", []string{"10.7.0.2/32", "10.8.0.2/24"}, false},
		{"later IPv6 cannot rescue first", []string{"fd00:7::2/128", "fd00:8::2/64"}, false},
		{"later IPv4 host is allowed", []string{"10.8.0.2/24", "10.7.0.2/32"}, true},
		{"later IPv6 host is allowed", []string{"fd00:8::2/64", "fd00:7::2/128"}, true},
		{"dual bad IPv4", []string{"fd00:7::2/127", "10.7.0.3/31"}, false},
		{"dual bad IPv6", []string{"10.7.0.2/31", "fd00:7::3/127"}, false},
		{"dual interleaved", []string{"fd00:7::2/127", "10.7.0.2/31", "fd00:8::2/128", "10.8.0.2/32"}, true},
	}
	stacks := []struct {
		name  string
		value string
		omit  bool
	}{
		{"gvisor", "gvisor", false},
		{"mixed", "mixed", false},
		{"system", "system", false},
		{"empty", "", false},
		{"omitted", "", true},
	}
	for _, prefixes := range prefixCases {
		for _, choice := range stacks {
			t.Run(prefixes.name+"/"+choice.name, func(t *testing.T) {
				config := testConfig(t)
				config.Addresses = prefixes.addresses
				config = testCustomBoxTUN(t, config, func(inbound map[string]any) {
					if choice.omit {
						delete(inbound, "stack")
					} else {
						inbound["stack"] = choice.value
					}
				})
				wantOK := choice.value == "gvisor" || prefixes.systemOK
				_, validationErr := Validate(config)
				if (validationErr == nil) != wantOK {
					t.Errorf("offline validation error = %v, want accepted=%v", validationErr, wantOK)
				}
				actual, constructorErr := singTun.NewStack(choice.value, boxConstructorOptions(prefixes.addresses))
				if (constructorErr == nil) != wantOK {
					t.Errorf("real constructor error = %v, want accepted=%v", constructorErr, wantOK)
				}
				if choice.value == "" && constructorErr == nil {
					if _, ok := actual.(*singTun.Mixed); !ok {
						t.Fatalf("empty stack constructed %T, want *tun.Mixed", actual)
					}
				}
			})
		}
	}
}

func TestAndroidOfflineValidation(t *testing.T) {
	ctx := transport.WithSocketProtector(context.Background(), func(int) error {
		panic("offline validation attempted socket protection")
	})
	for _, autoDetect := range []bool{false, true} {
		config := testCustomBox(t, testConfig(t), func(document map[string]any) {
			document["route"].(map[string]any)["auto_detect_interface"] = autoDetect
			document["outbounds"] = append(document["outbounds"].([]any), map[string]any{"type": "direct", "tag": "bypass"})
		})
		// JNI validation has no protector. Both contexts must stay offline.
		for _, parent := range []context.Context{context.Background(), ctx} {
			settings, err := validateForPlatform(parent, config, "android")
			if err != nil {
				t.Fatalf("Android offline validation (auto_detect=%v): %v", autoDetect, err)
			}
			if !reflect.DeepEqual(settings.Addresses, config.Addresses) {
				t.Fatal("Android validation changed network settings")
			}
		}
		boxCtx := validationBoxContext(ctx, config, "android")
		platform, ok := service.FromContext[adapter.PlatformInterface](boxCtx).(*suppliedTUNPlatform)
		if !ok || platform.fd != -1 || !platform.closed || !platform.android || platform.UnderNetworkExtension() {
			t.Fatal("validation did not install the closed Android platform")
		}
		if _, err := platform.duplicate(); !errors.Is(err, net.ErrClosed) {
			t.Fatalf("validation platform allowed descriptor access: %v", err)
		}
		options, err := parseBoxConfig(boxCtx, config)
		if err != nil {
			t.Fatal(err)
		}
		instance, err := box.New(box.Options{Context: boxCtx, Options: options})
		if err != nil {
			t.Fatal(err)
		}
		network := service.FromContext[adapter.NetworkManager](boxCtx)
		if network.NetworkMonitor() != nil || network.InterfaceMonitor() != nil || network.DefaultNetworkInterface() != nil {
			t.Fatal("Android constructor created an OS monitor or invented an interface")
		}
		if err := instance.Close(); err != nil {
			t.Fatal(err)
		}
		// Construction still checks WGC outbound references, without Start.
		invalid := testCustomBox(t, config, func(document map[string]any) {
			document["outbounds"].([]any)[0].(map[string]any)["peer"] = "undeclared"
		})
		if _, err := validateForPlatform(ctx, invalid, "android"); err == nil {
			t.Fatal("Android validation skipped sing-box semantic initialization")
		}
	}
	invalid := testConfig(t)
	invalid.Transport.Options = json.RawMessage(`{"listen":"private-listen-host.invalid:0"}`)
	// Transport preflight must win before any sing-box/TUN initialization.
	invalid.SingBox = json.RawMessage(`{}`)
	if _, err := validateForPlatform(ctx, invalid, "android"); err == nil || err.Error() != "UDP listen host must be numeric when socket protection is required" {
		t.Fatalf("Android transport preflight did not reject the hostname first: %v", err)
	}
	for _, goos := range []string{"darwin", "ios"} {
		if service.FromContext[adapter.PlatformInterface](validationBoxContext(context.Background(), testConfig(t), goos)) != nil {
			t.Fatal("Apple offline validation gained an Android platform")
		}
	}
}

func TestAndroidMonitorFreeRouteAndDNSPredicates(t *testing.T) {
	for _, field := range []string{"network_type", "network_is_expensive", "network_is_constrained"} {
		t.Run(field, func(t *testing.T) {
			var condition any = true
			if field == "network_type" {
				condition = []string{"wifi"}
			}
			config := testCustomBox(t, testConfig(t), func(document map[string]any) {
				document["route"].(map[string]any)["rules"] = []map[string]any{{field: condition, "outbound": "vpn"}}
				document["dns"].(map[string]any)["rules"] = []map[string]any{{field: condition, "server": "dns-remote"}}
			})
			ctx := validationBoxContext(context.Background(), config, "android")
			options, err := parseBoxConfig(ctx, config)
			if err != nil {
				t.Fatal(err)
			}
			instance, err := box.New(box.Options{Context: ctx, Options: options})
			if err != nil {
				t.Fatal(err)
			}
			defer instance.Close()
			// Exercise the actual pinned route/DNS rule Match methods. No rule
			// evaluation performs a DNS query or requires starting the box/TUN.
			if len(instance.Router().Rules()) != 1 {
				t.Fatal("sing-box did not construct the network route predicate")
			}
			for _, routeRule := range instance.Router().Rules() {
				if routeRule.Match(&adapter.InboundContext{}) {
					t.Fatal("route predicate matched an unknown underlying network")
				}
			}
			dnsRule, err := rule.NewDNSRule(ctx, log.NewNOPFactory().Logger(), options.DNS.Rules[0], true, false)
			if err != nil {
				t.Fatal(err)
			}
			if dnsRule.Match(&adapter.InboundContext{}) {
				t.Fatal("DNS predicate matched an unknown underlying network")
			}
		})
	}
}

func TestCustomBoxAddressSemanticEquality(t *testing.T) {
	for _, test := range []struct {
		name      string
		addresses []string
		tun       []string
		valid     bool
	}{
		{"expanded top-level IPv6", []string{"FD00:0007:0000:0000:0000:0000:0000:0002/64"}, []string{"fd00:7::2/64"}, true},
		{"expanded custom IPv6", []string{"fd00:7::2/64"}, []string{"FD00:0007:0000:0000:0000:0000:0000:0002/64"}, true},
		{"IPv4 host bits retained", []string{"10.7.0.2/24"}, []string{"10.7.0.2/24"}, true},
		{"IPv6 different host", []string{"fd00:7::2/64"}, []string{"fd00:7::3/64"}, false},
		{"IPv6 different prefix", []string{"fd00:7::2/64"}, []string{"fd00:7::2/128"}, false},
		{"IPv6 masked host", []string{"fd00:7::2/64"}, []string{"fd00:7::/64"}, false},
		{"IPv4 masked host", []string{"10.7.0.2/24"}, []string{"10.7.0.0/24"}, false},
		{"order differs", []string{"fd00:7::2/128", "10.7.0.2/32"}, []string{"10.7.0.2/32", "fd00:7::2/128"}, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			config := testConfig(t)
			config.Addresses = test.addresses
			config = testCustomBoxTUN(t, config, func(inbound map[string]any) {
				inbound["address"] = test.tun
			})
			settings, err := Validate(config)
			if (err == nil) != test.valid {
				t.Fatalf("Validate error = %v, want valid=%v", err, test.valid)
			}
			if test.valid && !reflect.DeepEqual(settings.Addresses, test.addresses) {
				t.Fatalf("interface host bits or spelling changed: %v", settings.Addresses)
			}
		})
	}
}
