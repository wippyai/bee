//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/wippyai/bee/native/client/mesh"
)

func TestInboxSeparatesClipboardFromConcurrentCall(t *testing.T) {
	c, source, _ := fixture(t)
	in := c.actor.(*inbox)
	go func() {
		call := <-source.body
		source.replies <- mesh.Message{From: ownerPID, Topic: clipboardTopic, Body: []byte(`{"text":"copy"}`)}
		source.replies <- reply(call.ID)
	}()
	if _, err := c.Call(callContext(t), operation()); err != nil {
		t.Fatal(err)
	}
	message, err := in.receive(callContext(t), in.clipboard)
	if err != nil || !samePID(message.From, ownerPID) || string(message.Body) != `{"text":"copy"}` {
		t.Fatalf("clipboard lost or changed: %#v %v", message, err)
	}
}

func TestInboxOverflowRetiresQueuedRequests(t *testing.T) {
	for _, topic := range []string{replyTopic, clipboardTopic} {
		t.Run(topic, func(t *testing.T) {
			c, source, _ := fixture(t)
			in := c.actor.(*inbox)
			for range inboxCapacity + 1 {
				select {
				case source.replies <- mesh.Message{From: ownerPID, Topic: topic, Body: []byte(`{}`)}:
				case <-time.After(time.Second):
					t.Fatal("dispatcher stalled")
				}
			}
			select {
			case <-in.done:
			case <-time.After(time.Second):
				t.Fatal("overflow did not retire inbox")
			}
			for _, queue := range []chan mesh.Message{in.replies, in.clipboard} {
				if _, err := in.receive(context.Background(), queue); !errors.Is(err, ErrInboxOverflow) {
					t.Fatalf("queued operation survived retirement: %v", err)
				}
			}
		})
	}
}

func TestInboxCloseJoinsReaderAndRejectsQueuedCopy(t *testing.T) {
	c, source, _ := fixture(t)
	in := c.actor.(*inbox)
	source.replies <- mesh.Message{From: ownerPID, Topic: clipboardTopic, Body: []byte(`{}`)}
	c.Close()
	select {
	case <-in.done:
	default:
		t.Fatal("reader survived close")
	}
	if _, err := in.receive(context.Background(), in.clipboard); !errors.Is(err, context.Canceled) {
		t.Fatalf("retired copy returned: %v", err)
	}
}
