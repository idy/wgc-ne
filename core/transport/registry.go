// Package transport constructs WGC transports inside the native extension.
package transport

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"regexp"
	"sync"

	wgc "github.com/idy/wgc"
	udp "github.com/idy/wgc/transport"
)

// Spec selects a compiled-in transport. A wrapper may compose a base transport;
// an omitted base means standard UDP. Options are private to its implementation.
type Spec struct {
	Type    string          `json:"type"`
	Options json.RawMessage `json:"options,omitempty"`
	Base    *Spec           `json:"base,omitempty"`
}

type Factory func(context.Context, json.RawMessage) (wgc.Transport, error)
type Wrapper func(context.Context, wgc.Transport, json.RawMessage) (wgc.Transport, error)

type entry struct {
	factory Factory
	wrapper Wrapper
}
type Registry struct {
	mu      sync.RWMutex
	entries map[string]entry
}

var validName = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,63}$`)
var Default = NewRegistry()

func NewRegistry() *Registry {
	return &Registry{entries: map[string]entry{"udp": {factory: openUDP}}}
}

func (r *Registry) register(name string, value entry) error {
	if !validName.MatchString(name) || (value.factory == nil && value.wrapper == nil) {
		return errors.New("invalid transport registration")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.entries == nil {
		r.entries = make(map[string]entry)
	}
	if _, exists := r.entries[name]; exists {
		return fmt.Errorf("transport %q already registered", name)
	}
	r.entries[name] = value
	return nil
}

func (r *Registry) RegisterFactory(name string, factory Factory) error {
	return r.register(name, entry{factory: factory})
}
func (r *Registry) RegisterWrapper(name string, wrapper Wrapper) error {
	return r.register(name, entry{wrapper: wrapper})
}
func RegisterFactory(name string, factory Factory) error {
	return Default.RegisterFactory(name, factory)
}
func RegisterWrapper(name string, wrapper Wrapper) error {
	return Default.RegisterWrapper(name, wrapper)
}

func (r *Registry) Validate(spec Spec) error { return r.validate(spec, 0) }
func (r *Registry) validate(spec Spec, depth int) error {
	if depth > 8 {
		return errors.New("transport nesting exceeds eight wrappers")
	}
	if spec.Type == "" {
		spec.Type = "udp"
	}
	r.mu.RLock()
	value, found := r.entries[spec.Type]
	r.mu.RUnlock()
	if !found {
		return fmt.Errorf("transport %q is not compiled into this core", spec.Type)
	}
	if len(spec.Options) > 0 && (!json.Valid(spec.Options) || bytes.Equal(bytes.TrimSpace(spec.Options), []byte("null"))) {
		return errors.New("invalid transport options")
	}
	if value.wrapper != nil {
		base := Spec{Type: "udp"}
		if spec.Base != nil {
			base = *spec.Base
		}
		return r.validate(base, depth+1)
	}
	if spec.Base != nil {
		return errors.New("base is only valid for a transport wrapper")
	}
	return nil
}

// Open closes a wrapper's base if construction fails. On success the returned
// transport owns its base, and must close it when Close is called.
func (r *Registry) Open(ctx context.Context, spec Spec) (wgc.Transport, error) {
	if err := r.Validate(spec); err != nil {
		return nil, err
	}
	return r.open(ctx, spec)
}
func (r *Registry) open(ctx context.Context, spec Spec) (wgc.Transport, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if spec.Type == "" {
		spec.Type = "udp"
	}
	r.mu.RLock()
	value := r.entries[spec.Type]
	r.mu.RUnlock()
	options := spec.Options
	if len(options) == 0 {
		options = json.RawMessage(`{}`)
	}
	if value.wrapper == nil {
		result, err := value.factory(ctx, options)
		if err != nil {
			if result != nil {
				_ = result.Close()
			}
			return nil, err
		}
		if result == nil {
			return nil, errors.New("transport factory returned nil")
		}
		return result, nil
	}
	base := Spec{Type: "udp"}
	if spec.Base != nil {
		base = *spec.Base
	}
	inner, err := r.open(ctx, base)
	if err != nil {
		return nil, err
	}
	result, err := value.wrapper(ctx, inner, options)
	if err != nil || result == nil {
		_ = inner.Close()
		if err == nil {
			err = errors.New("transport wrapper returned nil")
		}
		return nil, err
	}
	return result, nil
}

func openUDP(ctx context.Context, raw json.RawMessage) (wgc.Transport, error) {
	var options struct {
		Listen string `json:"listen,omitempty"`
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&options) != nil || decoder.Decode(new(any)) != io.EOF {
		return nil, errors.New("invalid UDP options")
	}
	address := options.Listen
	if address == "" {
		address = ":0"
	}
	listener := net.ListenConfig{}
	conn, err := listener.ListenPacket(ctx, "udp", address)
	if err != nil {
		return nil, errors.New("cannot open UDP transport")
	}
	return udp.FromUDPConn(conn.(*net.UDPConn)), nil
}
