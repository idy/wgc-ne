//go:build unix

package native

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/idy/wgc-ne/core"
	"golang.org/x/sys/unix"
)

func protectedStartConfig(t *testing.T) []byte {
	t.Helper()
	private, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	peer, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(core.Config{
		Version: 1, PrivateKey: base64.StdEncoding.EncodeToString(private.Bytes()),
		Addresses: []string{"10.7.0.2/32"},
		Peers:     []core.Peer{{ID: "exit", PublicKey: base64.StdEncoding.EncodeToString(peer.PublicKey().Bytes()), Endpoint: "127.0.0.1:9"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestProtectedStartFailureConsumesFDAndProtector(t *testing.T) {
	for _, valid := range []bool{false, true} {
		t.Run(map[bool]string{false: "bad-configuration", true: "protection-failure"}[valid], func(t *testing.T) {
			reader, writer, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			defer reader.Close()
			defer writer.Close()
			owned, err := unix.Dup(int(reader.Fd()))
			if err != nil {
				t.Fatal(err)
			}
			var calls, releases atomic.Int32
			raw := []byte(`{"private_key":"private-error-must-not-leak"}`)
			if valid {
				raw = protectedStartConfig(t)
			}
			var bridge Bridge
			answer := bridge.StartWithSocketProtector(owned, raw, func(fd int) error {
				calls.Add(1)
				if fd == owned {
					t.Error("TUN fd must never be passed to socket protection")
				}
				return errors.New("private-error-must-not-leak")
			}, func() { releases.Add(1) })
			if strings.Contains(answer, "private-error-must-not-leak") || !strings.Contains(answer, `"ok":false`) {
				t.Fatalf("unsafe failure response: %s", answer)
			}
			if valid && (runtime.GOOS == "darwin" || runtime.GOOS == "ios" || runtime.GOOS == "android") && calls.Load() == 0 {
				t.Fatal("native start did not propagate socket protection to UDP")
			}
			if releases.Load() != 1 || len(bridge.engines) != 0 {
				t.Fatal("failed startup retained its protector or published a handle")
			}
			if _, err := unix.FcntlInt(uintptr(owned), unix.F_GETFD, 0); err != unix.EBADF {
				t.Fatalf("failed startup leaked owned TUN fd: %v", err)
			}
			if _, err := unix.FcntlInt(reader.Fd(), unix.F_GETFD, 0); err != nil {
				t.Fatalf("failed startup closed host's original fd: %v", err)
			}
			bridge.Stop(0)
			if releases.Load() != 1 {
				t.Fatal("failed startup released protector twice")
			}
		})
	}
}
