//go:build with_gvisor

package core

import (
	"context"
	"encoding/json"
	"net/netip"
	"reflect"
	"testing"

	"github.com/sagernet/gvisor/pkg/tcpip/stack"
	"github.com/sagernet/sing-box/option"
	singTun "github.com/sagernet/sing-tun"
)

func testCustomBoxTUN(t *testing.T, config Config, change func(map[string]any)) Config {
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
	change(document["inbounds"].([]any)[0].(map[string]any))
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
