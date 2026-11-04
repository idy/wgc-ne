package core

import (
	"context"

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
	protect control.Func
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
		value = &protectedNetworkManager{NetworkManager: value.(adapter.NetworkManager), protect: r.protect}
	}
	return r.Registry.Register(key, value)
}

func (r *protectedServiceRegistry) Clone() service.Registry {
	return &protectedServiceRegistry{Registry: r.Registry.Clone(), protect: r.protect}
}

func protectedBoxContext(ctx context.Context) context.Context {
	if !transport.HasSocketProtector(ctx) {
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
