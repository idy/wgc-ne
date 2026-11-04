// Package register demonstrates a transparent, application-owned wrapper.
// It changes no packet bytes and contains no obfuscation algorithm.
package register

import (
	"context"
	"encoding/json"
	"net/netip"
	"sync/atomic"

	wgc "github.com/idy/wgc"
	"github.com/idy/wgc-ne/core/transport"
)

func init() {
	if err := transport.RegisterWrapper("counter", func(_ context.Context, base wgc.Transport, _ json.RawMessage) (wgc.Transport, error) {
		return &Counter{Transport: base}, nil
	}); err != nil {
		panic(err)
	}
}

type Counter struct {
	wgc.Transport
	Sent, Received atomic.Uint64
}

func (c *Counter) WriteTo(packet []byte, address netip.AddrPort) (int, error) {
	n, err := c.Transport.WriteTo(packet, address)
	c.Sent.Add(uint64(n))
	return n, err
}
func (c *Counter) ReadFrom(packet []byte) (int, netip.AddrPort, error) {
	n, address, err := c.Transport.ReadFrom(packet)
	c.Received.Add(uint64(n))
	return n, address, err
}
