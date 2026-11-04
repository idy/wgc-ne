package transport

import (
	"context"
	"encoding/json"
	"errors"
	"net/netip"
	"sync/atomic"
	"testing"

	wgc "github.com/idy/wgc"
)

type testTransport struct{ closes atomic.Int32 }

func (t *testTransport) ReadFrom([]byte) (int, netip.AddrPort, error) {
	return 0, netip.AddrPort{}, errors.New("unused")
}
func (t *testTransport) WriteTo(p []byte, _ netip.AddrPort) (int, error) { return len(p), nil }
func (t *testTransport) Close() error                                    { t.closes.Add(1); return nil }

func TestWrapperFailureClosesBase(t *testing.T) {
	r := NewRegistry()
	base := &testTransport{}
	if err := r.RegisterFactory("test", func(context.Context, json.RawMessage) (wgc.Transport, error) { return base, nil }); err != nil {
		t.Fatal(err)
	}
	if err := r.RegisterWrapper("broken", func(context.Context, wgc.Transport, json.RawMessage) (wgc.Transport, error) {
		return nil, errors.New("failed")
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Open(context.Background(), Spec{Type: "broken", Base: &Spec{Type: "test"}}); err == nil {
		t.Fatal("failure accepted")
	}
	if base.closes.Load() != 1 {
		t.Fatal("base leaked or closed twice")
	}
}
func TestRegistrationAndValidationDoNotOpenNetwork(t *testing.T) {
	r := NewRegistry()
	var opened atomic.Bool
	factory := func(context.Context, json.RawMessage) (wgc.Transport, error) {
		opened.Store(true)
		return &testTransport{}, nil
	}
	if err := r.RegisterFactory("private-custom", factory); err != nil {
		t.Fatal(err)
	}
	if err := r.RegisterFactory("private-custom", factory); err == nil {
		t.Fatal("duplicate registration accepted")
	}
	for _, name := range []string{"", "../bad", "Bad", "space name"} {
		if err := r.RegisterFactory(name, factory); err == nil {
			t.Fatal("invalid name accepted")
		}
	}
	if err := r.Validate(Spec{Type: "private-custom"}); err != nil {
		t.Fatal(err)
	}
	if opened.Load() {
		t.Fatal("validation opened a transport")
	}
	if _, err := r.Open(context.Background(), Spec{Type: "missing"}); err == nil {
		t.Fatal("unknown transport fell back")
	}
	if opened.Load() {
		t.Fatal("unknown transport opened a factory")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := r.Open(ctx, Spec{Type: "private-custom"}); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}
func TestDefaultUDPAndWrapperOwnership(t *testing.T) {
	r := NewRegistry()
	if err := r.RegisterWrapper("passthrough", func(_ context.Context, base wgc.Transport, _ json.RawMessage) (wgc.Transport, error) {
		return base, nil
	}); err != nil {
		t.Fatal(err)
	}
	conn, err := r.Open(context.Background(), Spec{Type: "passthrough"})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	nested := Spec{Type: "udp"}
	for i := 0; i < 20; i++ {
		next := nested
		nested = Spec{Type: "passthrough", Base: &next}
	}
	if err := r.Validate(nested); err == nil {
		t.Fatal("unbounded wrapper nesting accepted")
	}
	if err := r.Validate(Spec{Type: "udp", Base: &Spec{Type: "udp"}}); err == nil {
		t.Fatal("factory with base accepted")
	}
}
