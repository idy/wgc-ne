package core

import (
	"context"
	"errors"
	"runtime"
	"runtime/debug"
	"sync"

	"github.com/idy/wgc-ne/core/transport"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing/service"
)

type Engine struct {
	box      *box.Box
	session  *Session
	platform *suppliedTUNPlatform
	cancel   context.CancelFunc
	done     chan struct{}
	once     sync.Once
	err      error
}

func transportRegistryValidate(config Config) error {
	return transport.Default.Validate(config.Transport)
}

// Open takes ownership of fd on EVERY path. The host installs validated VPN
// settings first, then transfers an Apple utun or Android VpnService TUN fd.
// Android requires transport.WithSocketProtector on ctx before opening any
// sockets. The caller must keep its protector alive until the engine closes.
func Open(ctx context.Context, fd int, config Config, options SessionOptions) (*Engine, error) {
	return openForPlatform(ctx, fd, config, options, runtime.GOOS)
}

func openForPlatform(ctx context.Context, fd int, config Config, options SessionOptions, goos string) (_ *Engine, err error) {
	platform := &suppliedTUNPlatform{fd: fd, android: goos == "android", ctx: ctx}
	defer func() {
		if err != nil {
			platform.Close()
		}
	}()
	if goos != "darwin" && goos != "ios" && goos != "android" {
		return nil, errors.New("a supplied TUN requires an Apple or Android platform")
	}
	if fd < 0 {
		return nil, errors.New("owned TUN descriptor required")
	}
	if platform.android && !transport.HasSocketProtector(ctx) {
		return nil, transport.ErrSocketProtectorRequired
	}
	config, err = NormalizeConfig(config)
	if err != nil {
		return nil, err
	}
	if runtime.GOOS == "ios" {
		debug.SetMemoryLimit(32 << 20)
		debug.SetGCPercent(25)
	}
	runCtx, cancel := context.WithCancel(ctx)
	platform.ctx = runCtx
	defer func() {
		if err != nil {
			cancel()
		}
	}()
	session, err := NewSession(runCtx, config, options)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			_ = session.Close()
		}
	}()
	boxCtx := service.ContextWith[adapter.PlatformInterface](boxContext(runCtx, config, session), platform)
	parsed, err := parseBoxConfig(boxCtx, config)
	if err != nil {
		return nil, err
	}
	instance, err := box.New(box.Options{Context: boxCtx, Options: parsed})
	if err != nil {
		return nil, err
	}
	engine := &Engine{box: instance, session: session, platform: platform, cancel: cancel, done: make(chan struct{})}
	if err := instance.Start(); err != nil {
		_ = engine.Close()
		return nil, err
	}
	go func() {
		select {
		case <-session.Done():
			_ = engine.Close()
		case <-engine.done:
		}
	}()
	return engine, nil
}
func (e *Engine) Status() Status { return e.session.Status() }

// Done closes after all engine resources have been closed, including the TUN.
func (e *Engine) Done() <-chan struct{} { return e.done }

func (e *Engine) Close() error {
	e.once.Do(func() { e.cancel(); e.err = e.box.Close(); _ = e.session.Close(); e.platform.Close(); close(e.done) })
	return e.err
}
