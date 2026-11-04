package native

import (
	"context"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/idy/wgc-ne/core"
)

type startupTestEngine struct {
	ctx                 context.Context
	closes              atomic.Int32
	canceledBeforeClose atomic.Bool
}

func (e *startupTestEngine) Status() core.Status { return core.Status{State: "running"} }
func (e *startupTestEngine) Close() error {
	e.canceledBeforeClose.Store(e.ctx.Err() != nil)
	e.closes.Add(1)
	return nil
}

func TestStartupPublishedContextSurvivesBudgetUntilStop(t *testing.T) {
	ctx, startup := newStartupGate(100 * time.Millisecond)
	t.Cleanup(startup.cancel)
	engine := &startupTestEngine{ctx: ctx}
	var bridge Bridge
	id, ok := bridge.publish(engine, startup)
	if !ok || id == 0 {
		t.Fatal("startup did not publish a handle")
	}
	t.Cleanup(func() { bridge.Stop(id) })
	if _, hasDeadline := ctx.Deadline(); hasDeadline {
		t.Fatal("successful engine inherited a startup deadline")
	}

	// Also exercise a timer callback that was queued before commit stopped it.
	startup.abort()
	pastBudget := time.NewTimer(time.Until(startup.deadline) + 20*time.Millisecond)
	defer pastBudget.Stop()
	select {
	case <-ctx.Done():
		t.Fatal("successful engine was canceled by its startup timer")
	case <-pastBudget.C:
	}
	if engine.closes.Load() != 0 || !strings.Contains(bridge.Status(id), `"state":"running"`) {
		t.Fatal("published engine did not remain running")
	}

	bridge.Stop(id)
	if ctx.Err() != context.Canceled {
		t.Fatal("Stop did not cancel the owned root context")
	}
	if engine.closes.Load() != 1 || !engine.canceledBeforeClose.Load() {
		t.Fatal("Stop did not cancel the root before closing the engine")
	}
	bridge.Stop(id)
	if engine.closes.Load() != 1 || !strings.Contains(bridge.Status(id), `"code":"closed"`) {
		t.Fatal("Stop did not retire the handle idempotently")
	}
}

func TestStartupRejectsLatePublicationWithDelayedTimer(t *testing.T) {
	ctx, startup := newStartupGate(20 * time.Millisecond)
	t.Cleanup(startup.cancel)
	// Suppress the callback to model a timer goroutine that has not run yet.
	if !startup.timer.Stop() {
		t.Fatal("startup timer fired before the test could delay it")
	}
	pastBudget := time.NewTimer(time.Until(startup.deadline) + 10*time.Millisecond)
	defer pastBudget.Stop()
	<-pastBudget.C

	engine := &startupTestEngine{ctx: ctx}
	var bridge Bridge
	id, ok := bridge.publish(engine, startup)
	if ok || id != 0 || len(bridge.engines) != 0 || bridge.next != 0 {
		t.Fatal("late startup published a handle")
	}
	if ctx.Err() != context.Canceled {
		t.Fatal("late startup retained an uncanceled root context")
	}
	if engine.closes.Load() != 1 || !engine.canceledBeforeClose.Load() {
		t.Fatal("late engine was not canceled and closed")
	}
}

func TestStartupTimeoutPublicationRace(t *testing.T) {
	var publications, timeouts int
	for range 200 {
		ctx, startup := newStartupGate(time.Hour)
		engine := &startupTestEngine{ctx: ctx}
		var bridge Bridge
		var id uint64
		var published bool
		race := make(chan struct{})
		var workers sync.WaitGroup
		workers.Add(2)
		go func() {
			defer workers.Done()
			<-race
			// This is the same callback used by the startup timer.
			startup.abort()
		}()
		go func() {
			defer workers.Done()
			<-race
			id, published = bridge.publish(engine, startup)
		}()
		close(race)
		workers.Wait()

		if published {
			publications++
			if id == 0 || len(bridge.engines) != 1 || ctx.Err() != nil || engine.closes.Load() != 0 {
				t.Error("timeout canceled an engine whose publication won")
			}
			bridge.Stop(id)
		} else {
			timeouts++
			if id != 0 || len(bridge.engines) != 0 || bridge.next != 0 {
				t.Error("timeout lost handle publication after cancellation")
			}
		}
		if ctx.Err() != context.Canceled || engine.closes.Load() != 1 || !engine.canceledBeforeClose.Load() {
			t.Error("startup race did not release the root context and engine exactly once")
		}
		startup.cancel()
	}
	t.Logf("publication won %d races; timeout won %d races", publications, timeouts)
}
