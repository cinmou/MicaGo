package realtime

import (
	"context"
	"testing"

	"nhooyr.io/websocket"
)

func TestHubRegisterUnregisterAndEmptyBroadcast(t *testing.T) {
	hub := NewHub()
	conn1 := &websocket.Conn{}
	conn2 := &websocket.Conn{}

	hub.add(conn1)
	hub.add(conn2)

	if hub.ClientCount() != 2 {
		t.Fatalf("expected 2 clients, got %d", hub.ClientCount())
	}

	hub.remove(conn1)
	if hub.ClientCount() != 1 {
		t.Fatalf("expected 1 client after remove, got %d", hub.ClientCount())
	}

	hub.remove(conn2)
	if hub.ClientCount() != 0 {
		t.Fatalf("expected 0 clients after cleanup, got %d", hub.ClientCount())
	}

	if err := hub.Broadcast(context.Background(), Event{Type: "message:new", Data: map[string]any{"guid": "msg-1"}}); err != nil {
		t.Fatalf("expected empty broadcast to succeed, got %v", err)
	}
}
