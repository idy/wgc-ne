package core

import (
	"context"
	"syscall"

	"github.com/idy/wgc-ne/core/transport"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing/common/control"
	"github.com/sagernet/sing/service"
)

// sing-box v1.14.4 only installs PlatformInterface's protection control when
// auto_detect_interface is enabled, and skips it for explicit bind options.
// Its DefaultDialer unconditionally appends AutoRedirectOutputMarkFunc to BOTH
// TCP/connected UDP dialers and UDP listeners. Compose protection at that hook,
// preserving the original mark control. This also covers DNS, implicit direct
// outbounds, HTTP clients and rule-set downloads. Keep the real NetworkManager
// for lifecycle/monitoring; every consumer of its service gets this decorator.
// The socket integration tests must run when upgrading the pinned sing-box.
type protectedNetworkManager struct {
	adapter.NetworkManager
	protect         control.Func
	suppliedAndroid bool
}

func (m *protectedNetworkManager) DefaultNetworkInterface() *adapter.NetworkInterface {
	// The supplied Android platform intentionally has no interface monitor.
	// The pinned manager dereferences it even for route/DNS network predicates.
	if m.InterfaceMonitor() == nil {
		return nil
	}
	return m.NetworkManager.DefaultNetworkInterface()
}

func (m *protectedNetworkManager) AutoDetectInterfaceFunc() control.Func {
	if m.suppliedAndroid {
		// This platform's auto-detect control only protects sockets; the
		// unconditional output-mark hook below already does that. Keep a nonnil
		// control because the pinned UDP listener calls autoDetectBindFunc.
		return func(string, string, syscall.RawConn) error { return nil }
	}
	return m.NetworkManager.AutoDetectInterfaceFunc()
}

func (m *protectedNetworkManager) AutoRedirectOutputMarkFunc() control.Func {
	return control.Append(m.protect, m.NetworkManager.AutoRedirectOutputMarkFunc())
}

type protectedServiceRegistry struct {
	service.Registry
	protect control.Func
}

func (r *protectedServiceRegistry) Register(key, value any) any {
	if key == (*adapter.NetworkManager)(nil) && value != nil {
		platform, _ := r.Get((*adapter.PlatformInterface)(nil)).(*suppliedTUNPlatform)
		value = &protectedNetworkManager{
			NetworkManager:  value.(adapter.NetworkManager),
			protect:         r.protect,
			suppliedAndroid: platform != nil && platform.android,
		}
	}
	return r.Registry.Register(key, value)
}

func (r *protectedServiceRegistry) Clone() service.Registry {
	return &protectedServiceRegistry{Registry: r.Registry.Clone(), protect: r.protect}
}

func protectedBoxContext(ctx context.Context) context.Context {
	platform, _ := service.FromContext[adapter.PlatformInterface](ctx).(*suppliedTUNPlatform)
	if !transport.HasSocketProtector(ctx) && !(platform != nil && platform.android) {
		return ctx
	}
	registry := service.RegistryFromContext(ctx)
	if registry == nil {
		registry = service.NewRegistry()
	} else {
		registry = registry.Clone()
	}
	return service.ContextWithRegistry(ctx, &protectedServiceRegistry{Registry: registry, protect: transport.SocketControl(ctx)})
}
