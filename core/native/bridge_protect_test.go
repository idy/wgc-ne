package native

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestProtectorReleasedAfterStopOrFailedPublication(t *testing.T) {
	for _, late := range []bool{false, true} {
		ctx, startup := newStartupGate(time.Hour)
		if late {
			startup.abort()
		}
		engine := &startupTestEngine{ctx: ctx}
		var releases atomic.Int32
		release := sync.OnceFunc(func() {
			if engine.closes.Load() == 0 || ctx.Err() != context.Canceled {
				t.Error("protector released before cancellation and engine close")
			}
			releases.Add(1)
		})
		owned := &releasingEngine{tunnelEngine: engine, release: release}
		var bridge Bridge
		id, ok := bridge.publish(owned, startup)
		if ok == late {
			t.Fatal("unexpected publication result")
		}
		if ok && releases.Load() != 0 {
			t.Fatal("running engine released its protector")
		}
		bridge.Stop(id)
		bridge.Stop(id)
		// A concurrent terminal-engine notification and Stop share one release.
		var workers sync.WaitGroup
		for range 8 {
			workers.Go(release)
		}
		workers.Wait()
		if releases.Load() != 1 || engine.closes.Load() != 1 {
			t.Fatalf("resources not released exactly once: protector=%d engine=%d", releases.Load(), engine.closes.Load())
		}
		startup.cancel()
	}
}
