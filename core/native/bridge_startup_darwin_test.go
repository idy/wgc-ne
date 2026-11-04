//go:build darwin

package native

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	wgc "github.com/idy/wgc"
	"github.com/idy/wgc-ne/core"
	"github.com/idy/wgc-ne/core/transport"
	"golang.org/x/sys/unix"
)

var startupFactoryID atomic.Uint64

func TestStartupFactoryFailureOwnsFDAndRedactsResponse(t *testing.T) {
	for _, test := range []struct {
		name    string
		wait    bool
		timeout time.Duration
	}{
		{name: "context_cancellation", wait: true, timeout: 100 * time.Millisecond},
		{name: "factory_error", timeout: time.Hour},
	} {
		t.Run(test.name, func(t *testing.T) {
			const secret = "startup-factory-private-option-must-not-leak"
			entered := make(chan context.Context, 1)
			rescue := make(chan struct{})
			factoryName := fmt.Sprintf("startup-test-%d", startupFactoryID.Add(1))
			if err := transport.RegisterFactory(factoryName, func(ctx context.Context, _ json.RawMessage) (wgc.Transport, error) {
				entered <- ctx
				if test.wait {
					select {
					case <-ctx.Done():
						return nil, fmt.Errorf("%s: %w", secret, ctx.Err())
					case <-rescue:
						return nil, errors.New("test rescued a stuck factory")
					}
				}
				return nil, errors.New(secret)
			}); err != nil {
				t.Fatal(err)
			}
			raw, privateKey := startupFactoryConfig(t, factoryName, secret)
			reader, writer, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = reader.Close(); _ = writer.Close() })
			originalFD := int(reader.Fd())
			ownedFD, err := unix.Dup(originalFD)
			if err != nil {
				t.Fatal(err)
			}

			var bridge Bridge
			answer := make(chan string, 1)
			done := make(chan struct{})
			t.Cleanup(func() {
				// A missing startup cancellation must fail the test without leaving
				// its factory goroutine or transferred descriptor blocked forever.
				close(rescue)
				select {
				case <-done:
					if _, err := unix.FcntlInt(uintptr(ownedFD), unix.F_GETFD, 0); err != unix.EBADF {
						_ = unix.Close(ownedFD)
						t.Errorf("core did not close the transferred duplicate: %v", err)
					}
				case <-time.After(2 * time.Second):
					t.Error("startup did not return after releasing the rescue channel")
				}
			})
			started := time.Now()
			go func() {
				answer <- bridge.start(ownedFD, raw, test.timeout)
				close(done)
			}()
			bound := time.NewTimer(2 * time.Second)
			defer bound.Stop()
			var factoryContext context.Context
			select {
			case factoryContext = <-entered:
			case <-bound.C:
				t.Fatal("startup did not enter the registered factory")
			}
			var response string
			select {
			case response = <-answer:
			case <-bound.C:
				t.Fatal("startup did not return within the test bound")
			}
			<-done
			if test.wait && time.Since(started) < test.timeout {
				t.Error("pending factory returned before its startup budget elapsed")
			}
			if factoryContext.Err() != context.Canceled {
				t.Error("failed startup retained an uncanceled factory context")
			}
			if response != failed("start_failed", "The tunnel core could not start") || strings.Contains(response, secret) || strings.Contains(response, privateKey) {
				t.Error("startup did not return the redacted failure envelope")
			}
			if len(bridge.engines) != 0 || bridge.next != 0 {
				t.Error("failed startup published a handle")
			}
			if _, err := unix.FcntlInt(uintptr(ownedFD), unix.F_GETFD, 0); err != unix.EBADF {
				t.Errorf("transferred duplicate is still open: %v", err)
			}
			if _, err := unix.FcntlInt(uintptr(originalFD), unix.F_GETFD, 0); err != nil {
				t.Errorf("core closed the caller's original descriptor: %v", err)
			}
		})
	}
}

func startupFactoryConfig(t *testing.T, factoryName, secret string) ([]byte, string) {
	t.Helper()
	private, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	peer, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	privateKey := base64.StdEncoding.EncodeToString(private.Bytes())
	options, err := json.Marshal(map[string]string{"token": secret})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(core.Config{
		Version:    1,
		PrivateKey: privateKey,
		Addresses:  []string{"10.7.0.2/32"},
		Peers: []core.Peer{{
			ID:        "exit",
			PublicKey: base64.StdEncoding.EncodeToString(peer.PublicKey().Bytes()),
			Endpoint:  "127.0.0.1:9",
		}},
		Transport: transport.Spec{Type: factoryName, Options: options},
	})
	if err != nil {
		t.Fatal(err)
	}
	return raw, privateKey
}
