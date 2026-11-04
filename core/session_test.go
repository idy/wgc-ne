//go:build with_gvisor

package core

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"

	wgc "github.com/idy/wgc"
	coreTransport "github.com/idy/wgc-ne/core/transport"
	udp "github.com/idy/wgc/transport"
	"github.com/sagernet/gvisor/pkg/buffer"
	"github.com/sagernet/gvisor/pkg/tcpip"
	"github.com/sagernet/gvisor/pkg/tcpip/adapters/gonet"
	"github.com/sagernet/gvisor/pkg/tcpip/header"
	"github.com/sagernet/gvisor/pkg/tcpip/link/channel"
	"github.com/sagernet/gvisor/pkg/tcpip/stack"
	"github.com/sagernet/sing-tun"
	M "github.com/sagernet/sing/common/metadata"
)

type countingTransport struct {
	wgc.Transport
	sent, received atomic.Uint64
}

func (c *countingTransport) WriteTo(b []byte, a netip.AddrPort) (int, error) {
	n, err := c.Transport.WriteTo(b, a)
	if n > 0 {
		c.sent.Add(uint64(n))
	}
	return n, err
}
func (c *countingTransport) ReadFrom(b []byte) (int, netip.AddrPort, error) {
	n, a, err := c.Transport.ReadFrom(b)
	if n > 0 {
		c.received.Add(uint64(n))
	}
	return n, a, err
}

func TestEncryptedTCPUDPAndCustomTransport(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	clientPrivate, clientPublic := testKeys(t)
	serverPrivate, serverPublic := testKeys(t)
	clientKey, _ := parseKey(clientPublic)
	serverKey, _ := parseKey(serverPrivate)
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	server, err := wgc.NewConn(udp.FromUDPConn(socket), wgc.Config{StaticPrivateKey: &serverKey, DisableStats: true, SharedWriteQueue: true, MaxPeers: 1, PeerConfigLookup: func(key wgc.Key) (*wgc.PeerConfig, error) {
		if key != clientKey {
			return nil, nil
		}
		return &wgc.PeerConfig{}, nil
	}})
	if err != nil {
		socket.Close()
		t.Fatal(err)
	}
	defer server.Close()
	link := channel.New(128, 1280, "")
	ipStack, err := tun.NewGVisorStackWithOptions(link, stack.NICOptions{}, true)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		cancel()
		_ = server.Close()
		link.Close()
		ipStack.Close()
		for _, endpoint := range ipStack.CleanupEndpoints() {
			endpoint.Abort()
		}
		ipStack.Wait()
	}()
	address := tun.AddressFromAddr(netip.MustParseAddr("10.7.0.1"))
	if err := ipStack.AddProtocolAddress(tun.DefaultNIC, tcpip.ProtocolAddress{Protocol: header.IPv4ProtocolNumber, AddressWithPrefix: tcpip.AddressWithPrefix{Address: address, PrefixLen: 32}}, stack.AddressProperties{}); err != nil {
		t.Fatal(err)
	}
	listener, err := gonet.ListenTCP(ipStack, tcpip.FullAddress{NIC: tun.DefaultNIC, Addr: address, Port: 8080}, header.IPv4ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	packetConn, err := gonet.DialUDP(ipStack, &tcpip.FullAddress{NIC: tun.DefaultNIC, Addr: address, Port: 8081}, nil, header.IPv4ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer packetConn.Close()
	go func() {
		for packet := range server.ReadQueue() {
			payload := append([]byte(nil), packet.Data...)
			packet.Release()
			buf := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(payload)})
			link.InjectInbound(header.IPv4ProtocolNumber, buf)
			buf.DecRef()
		}
	}()
	go func() {
		writer := server.PeerWriter(clientKey)
		for {
			packet := link.ReadContext(ctx)
			if packet == nil {
				return
			}
			var payload []byte
			for _, part := range packet.AsSlices() {
				payload = append(payload, part...)
			}
			_, _ = writer.Write(payload)
			packet.DecRef()
		}
	}()
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
		data, err := io.ReadAll(io.LimitReader(conn, 1<<20))
		if err == nil {
			_, _ = conn.Write(data)
		}
	}()
	go func() {
		payload := make([]byte, 2048)
		n, from, err := packetConn.ReadFrom(payload)
		if err == nil {
			_, _ = packetConn.WriteTo(payload[:n], from)
		}
	}()
	registry := coreTransport.NewRegistry()
	var counter *countingTransport
	if err := registry.RegisterWrapper("test-counter", func(_ context.Context, base wgc.Transport, _ json.RawMessage) (wgc.Transport, error) {
		counter = &countingTransport{Transport: base}
		return counter, nil
	}); err != nil {
		t.Fatal(err)
	}
	config := Config{Version: 1, PrivateKey: clientPrivate, Addresses: []string{"10.7.0.2/32"}, Peers: []Peer{{ID: "test", PublicKey: serverPublic, Endpoint: socket.LocalAddr().String()}}, Transport: coreTransport.Spec{Type: "test-counter"}}
	session, err := NewSession(ctx, config, SessionOptions{Registry: registry})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	deadline, cancelDial := context.WithTimeout(ctx, 10*time.Second)
	defer cancelDial()
	conn, err := session.DialPeer(deadline, "test", "tcp", "10.7.0.1:8080")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
	payload := bytes.Repeat([]byte("public-wgc-ne"), 4096)
	if _, err := conn.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := conn.(interface{ CloseWrite() error }).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	reply, err := io.ReadAll(conn)
	if err != nil || !bytes.Equal(reply, payload) {
		t.Fatalf("TCP round trip: bytes=%d err=%v", len(reply), err)
	}
	outbound := &peerOutbound{session: session, peer: "test"}
	udpConn, resolved, err := outbound.ListenPacketWithDestination(deadline, M.Socksaddr{Addr: netip.MustParseAddr("10.7.0.1"), Port: 8081})
	if err != nil {
		t.Fatal(err)
	}
	defer udpConn.Close()
	if resolved.String() != "10.7.0.1" {
		t.Fatal("incorrect resolved address")
	}
	_ = udpConn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := udpConn.WriteTo([]byte("udp-payload"), &net.UDPAddr{IP: net.IPv4(10, 7, 0, 1), Port: 8081}); err != nil {
		t.Fatal(err)
	}
	reply = make([]byte, 64)
	n, _, err := udpConn.ReadFrom(reply)
	if err != nil || string(reply[:n]) != "udp-payload" {
		t.Fatalf("UDP round trip: bytes=%d err=%v", n, err)
	}
	if counter.sent.Load() == 0 || counter.received.Load() == 0 {
		t.Fatal("custom transport was bypassed")
	}
	status := session.Status()
	if status.BytesSent == 0 || status.BytesReceived == 0 || status.PublicKey != clientPublic {
		t.Fatal("incorrect public status")
	}
	_ = session.Close()
	if _, err := session.DialPeer(deadline, "test", "tcp", "10.7.0.1:8080"); err == nil {
		t.Fatal("closed session accepted a dial")
	}
}
