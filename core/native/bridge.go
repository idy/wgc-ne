// Package native is the bounded, redacted control surface used by the C ABI.
package native

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/idy/wgc-ne/core"
	"github.com/idy/wgc-ne/core/transport"
)

const ABIVersion = 1

// Leave room for the provider's 10s settings step within its 35s total budget.
const startupTimeout = 20 * time.Second

type tunnelEngine interface {
	Status() core.Status
	Close() error
}

type runningEngine struct {
	tunnelEngine
	cancel context.CancelFunc
}

type Bridge struct {
	mu      sync.Mutex
	next    uint64
	engines map[uint64]*runningEngine
}

// A startup timer cancels pending Open work independently of the calling thread.
// On publication the timer is disarmed, but the root cancel belongs to Stop.
// Custom factories must respect this context to make startup bounded.
type startupGate struct {
	mu       sync.Mutex
	timer    *time.Timer
	deadline time.Time
	cancel   context.CancelFunc
	finished bool
}

func newStartupGate(timeout time.Duration) (context.Context, *startupGate) {
	ctx, cancel := context.WithCancel(context.Background())
	startup := &startupGate{deadline: time.Now().Add(timeout), cancel: cancel}
	startup.timer = time.AfterFunc(timeout, startup.abort)
	return ctx, startup
}

func (s *startupGate) abort() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.finished {
		s.finished = true
		s.cancel()
	}
}

func (s *startupGate) commit() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.timer.Stop()
	if s.finished {
		return false
	}
	s.finished = true
	// The timer callback may still be waiting to run when Open returns.
	if !time.Now().Before(s.deadline) {
		s.cancel()
		return false
	}
	return true
}

type response struct {
	OK     bool     `json:"ok"`
	Result any      `json:"result,omitempty"`
	Error  *failure `json:"error,omitempty"`
}
type failure struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func result(value any) string {
	raw, _ := json.Marshal(response{OK: true, Result: value})
	return string(raw)
}
func failed(code, message string) string {
	raw, _ := json.Marshal(response{Error: &failure{Code: code, Message: message}})
	return string(raw)
}

func Validate(raw []byte) string {
	config, err := core.DecodeConfig(raw)
	if err != nil {
		return failed("invalid_configuration", "Invalid tunnel configuration")
	}
	settings, err := core.Validate(config)
	if err != nil {
		return failed("invalid_configuration", "Invalid core configuration or unavailable transport")
	}
	return result(settings)
}
func (b *Bridge) Start(fd int, raw []byte) string {
	return b.start(fd, raw, startupTimeout)
}

// StartWithSocketProtector consumes fd and the optional release callback on
// EVERY path. It releases the protector after failed startup, engine shutdown,
// or Stop (exactly once). Protection callbacks may run concurrently until then.
// The C ABI v1 Start remains unchanged; Android JNI uses this entrypoint.
func (b *Bridge) StartWithSocketProtector(fd int, raw []byte, protector transport.SocketProtector, release func()) string {
	return b.startWithSocketProtector(fd, raw, startupTimeout, protector, release)
}

func (b *Bridge) start(fd int, raw []byte, timeout time.Duration) string {
	return b.startWithSocketProtector(fd, raw, timeout, nil, nil)
}

// A protector may own a JNI global reference. Engine.Close must finish before
// releasing it; release must also be safe against a callback already in flight.
type releasingEngine struct {
	tunnelEngine
	release func()
}

func (e *releasingEngine) Close() error {
	err := e.tunnelEngine.Close()
	e.release()
	return err
}

type terminatingEngine interface {
	tunnelEngine
	Done() <-chan struct{}
}

func engineWithRelease(engine terminatingEngine, release func()) tunnelEngine {
	if release == nil {
		return engine
	}
	// Core failures can close the engine before the host calls Stop. Retire the
	// protector promptly, while keeping the handle available for safe status.
	go func() { <-engine.Done(); release() }()
	return &releasingEngine{tunnelEngine: engine, release: release}
}

func (b *Bridge) startWithSocketProtector(fd int, raw []byte, timeout time.Duration, protector transport.SocketProtector, release func()) string {
	transferred := false
	if release != nil {
		release = sync.OnceFunc(release)
		defer func() {
			if !transferred {
				release()
			}
		}()
	}
	config, err := core.DecodeConfig(raw)
	if err != nil {
		core.CloseOwnedFD(fd)
		return failed("invalid_configuration", "Invalid tunnel configuration")
	}
	ctx, startup := newStartupGate(timeout)
	ctx = transport.WithSocketProtector(ctx, protector)
	engine, err := core.Open(ctx, fd, config, core.SessionOptions{})
	if err != nil {
		startup.timer.Stop()
		startup.abort()
		return failed("start_failed", "The tunnel core could not start")
	}
	owned := engineWithRelease(engine, release)
	transferred = true
	id, ok := b.publish(owned, startup)
	if !ok {
		return failed("start_failed", "The tunnel core could not start")
	}
	return result(map[string]uint64{"handle": id})
}

func (b *Bridge) publish(engine tunnelEngine, startup *startupGate) (uint64, bool) {
	b.mu.Lock()
	// Commit while holding the handle lock so timeout and publication have one
	// winner, even if Open returns after cancellation or a delayed timer callback.
	if !startup.commit() {
		b.mu.Unlock()
		_ = engine.Close()
		return 0, false
	}
	defer b.mu.Unlock()
	if b.engines == nil {
		b.engines = make(map[uint64]*runningEngine)
	}
	b.next++
	b.engines[b.next] = &runningEngine{tunnelEngine: engine, cancel: startup.cancel}
	return b.next, true
}
func (b *Bridge) Status(id uint64) string {
	b.mu.Lock()
	engine := b.engines[id]
	b.mu.Unlock()
	if engine == nil {
		return failed("closed", "Tunnel handle is closed")
	}
	return result(engine.Status())
}
func (b *Bridge) Stop(id uint64) {
	b.mu.Lock()
	engine := b.engines[id]
	delete(b.engines, id)
	b.mu.Unlock()
	if engine != nil {
		engine.cancel()
		_ = engine.Close()
	}
}
