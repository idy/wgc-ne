package native

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type releaseTestEngine struct {
	startupTestEngine
	done chan struct{}
	once sync.Once
}

func (e *releaseTestEngine) Done() <-chan struct{} {
	if e.done == nil {
		panic("engine without a release callback must not be watched")
	}
	return e.done
}
func (e *releaseTestEngine) Close() error {
	e.once.Do(func() { _ = e.startupTestEngine.Close(); close(e.done) })
	return nil
}

func TestEngineWithoutReleaseHasNoWrapperAllocationOrWatcher(t *testing.T) {
	engine := &releaseTestEngine{}
	allocations := testing.AllocsPerRun(100, func() {
		if engineWithRelease(engine, nil) != engine {
			t.Fatal("engine without release was wrapped")
		}
	})
	if allocations != 0 {
		t.Fatalf("engine without release allocated %v objects", allocations)
	}
}

func TestEngineReleaseAfterDoneStopOrFailedPublication(t *testing.T) {
	for _, mode := range []string{"stop", "done", "failed-publication"} {
		t.Run(mode, func(t *testing.T) {
			ctx, startup := newStartupGate(time.Hour)
			defer startup.cancel()
			if mode == "failed-publication" {
				startup.abort()
			}
			engine := &releaseTestEngine{startupTestEngine: startupTestEngine{ctx: ctx}, done: make(chan struct{})}
			released := make(chan struct{})
			var releases atomic.Int32
			owned := engineWithRelease(engine, sync.OnceFunc(func() {
				if engine.closes.Load() != 1 || ctx.Err() != context.Canceled {
					t.Error("release preceded engine shutdown and cancellation")
				}
				releases.Add(1)
				close(released)
			}))
			var bridge Bridge
			id, ok := bridge.publish(owned, startup)
			if ok != (mode != "failed-publication") {
				t.Fatal("unexpected publication result")
			}
			if mode == "done" {
				startup.cancel()
				_ = engine.Close()
			} else {
				bridge.Stop(id)
			}
			select {
			case <-released:
			case <-time.After(time.Second):
				t.Fatal("terminal engine retained its release callback")
			}
			bridge.Stop(id)
			bridge.Stop(id)
			if releases.Load() != 1 || engine.closes.Load() != 1 {
				t.Fatal("Stop and Done did not share exactly one release")
			}
		})
	}
}

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
