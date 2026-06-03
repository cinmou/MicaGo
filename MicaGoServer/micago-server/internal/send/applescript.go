package send

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

type AppleScriptSender struct{}

func (s AppleScriptSender) SendText(ctx context.Context, chatGUID, message string) error {
	script := BuildSendToChatScript(chatGUID, message)
	cmd := exec.CommandContext(ctx, "osascript", "-e", script)
	output, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(output))
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("%s", msg)
	}
	return nil
}

func BuildSendToChatScript(chatGUID, message string) string {
	return fmt.Sprintf(`tell application "Messages"
  send "%s" to chat id "%s"
end tell`, escapeAppleScriptString(message), escapeAppleScriptString(chatGUID))
}

func escapeAppleScriptString(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, `"`, `\"`)
	return value
}
