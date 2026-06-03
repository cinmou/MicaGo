package send

import (
	"strings"
	"testing"
)

func TestEscapeAppleScriptString(t *testing.T) {
	got := escapeAppleScriptString(`a "quote" and \ slash`)
	if got != `a \"quote\" and \\ slash` {
		t.Fatalf("unexpected escaped string: %q", got)
	}
}

func TestBuildSendToChatScript(t *testing.T) {
	script := BuildSendToChatScript(`iMessage;-;abc"123`, `hello "world"`)
	if !strings.Contains(script, `send "hello \"world\""`) {
		t.Fatalf("expected escaped message in script: %s", script)
	}
	if !strings.Contains(script, `chat id "iMessage;-;abc\"123"`) {
		t.Fatalf("expected escaped chat guid in script: %s", script)
	}
}
