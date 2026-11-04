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
	platform *applePlatform
	cancel   context.CancelFunc
	done     chan struct{}
	once     sync.Once
	err      error
}

func transportRegistryValidate(config Config) error {
	return transport.Default.Validate(config.Transport)
}

// Open takes ownership of fd on EVERY path. The host must pass a duplicate of
// its own NetworkExtension utun descriptor and install validated settings first.
func Open(ctx context.Context, fd int, config Config, options SessionOptions) (_ *Engine, err error) {
	platform := &applePlatform{fd: fd}
	defer func() {
		if err != nil {
			platform.Close()
		}
	}()
	if runtime.GOOS != "darwin" && runtime.GOOS != "ios" {
		return nil, errors.New("NetworkExtension requires an Apple platform")
	}
	if fd < 0 {
		return nil, errors.New("owned TUN descriptor required")
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
func (e *Engine) Close() error {
	e.once.Do(func() { e.cancel(); e.err = e.box.Close(); _ = e.session.Close(); e.platform.Close(); close(e.done) })
	return e.err
}
