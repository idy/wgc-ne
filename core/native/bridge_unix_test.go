//go:build unix

package native

import (
	"encoding/json"
	"golang.org/x/sys/unix"
	"os"
	"strings"
	"testing"
)

func TestRejectedStartOwnsFDAndRedactsInput(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	fd, err := unix.Dup(int(reader.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	var bridge Bridge
	answer := bridge.Start(fd, []byte(`{"private_key":"must-not-leak"}`))
	if strings.Contains(answer, "must-not-leak") {
		t.Fatal("input leaked")
	}
	var parsed map[string]any
	if json.Unmarshal([]byte(answer), &parsed) != nil || parsed["ok"] != false {
		t.Fatal(answer)
	}
	if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != unix.EBADF {
		unix.Close(fd)
		t.Fatal("owned FD leaked")
	}
	bridge.Stop(0)
	bridge.Stop(0)
	if !strings.Contains(bridge.Status(0), `"code":"closed"`) {
		t.Fatal("missing closed error")
	}
}
