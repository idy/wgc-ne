// Package native is the bounded, redacted control surface used by the C ABI.
package native

import (
	"context"
	"encoding/json"
	"sync"

	"github.com/idy/wgc-ne/core"
)

const ABIVersion = 1

type Bridge struct {
	mu      sync.Mutex
	next    uint64
	engines map[uint64]*core.Engine
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
	config, err := core.DecodeConfig(raw)
	if err != nil {
		core.CloseOwnedFD(fd)
		return failed("invalid_configuration", "Invalid tunnel configuration")
	}
	engine, err := core.Open(context.Background(), fd, config, core.SessionOptions{})
	if err != nil {
		return failed("start_failed", "The tunnel core could not start")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.engines == nil {
		b.engines = make(map[uint64]*core.Engine)
	}
	b.next++
	b.engines[b.next] = engine
	return result(map[string]uint64{"handle": b.next})
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
		_ = engine.Close()
	}
}
