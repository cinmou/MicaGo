package realtime

import (
	"encoding/json"
	"testing"
)

func TestEventJSON(t *testing.T) {
	payload, err := json.Marshal(Event{
		Type: "message:new",
		Data: map[string]any{"guid": "msg-1"},
	})
	if err != nil {
		t.Fatal(err)
	}

	if string(payload) != `{"type":"message:new","data":{"guid":"msg-1"}}` {
		t.Fatalf("unexpected json %s", payload)
	}
}
