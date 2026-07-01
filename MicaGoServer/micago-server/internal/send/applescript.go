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

// SendAttachment sends a local file to the chat. Messages accepts a file
// reference; `POSIX file "<path>"` resolves an absolute path to that reference.
func (s AppleScriptSender) SendAttachment(ctx context.Context, chatGUID, filePath string) error {
	script := BuildSendAttachmentScript(chatGUID, filePath)
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

// SendAttachments sends several local files in one Messages AppleScript call.
// Messages accepts an AppleScript list of POSIX file references and groups the
// media into one outgoing message when the service supports it.
func (s AppleScriptSender) SendAttachments(ctx context.Context, chatGUID string, filePaths []string) error {
	if len(filePaths) == 0 {
		return nil
	}
	if len(filePaths) == 1 {
		return s.SendAttachment(ctx, chatGUID, filePaths[0])
	}
	script := BuildSendAttachmentsScript(chatGUID, filePaths)
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

func BuildSendAttachmentScript(chatGUID, filePath string) string {
	return fmt.Sprintf(`tell application "Messages"
  send (POSIX file "%s") to chat id "%s"
end tell`, escapeAppleScriptString(filePath), escapeAppleScriptString(chatGUID))
}

func BuildSendAttachmentsScript(chatGUID string, filePaths []string) string {
	parts := make([]string, 0, len(filePaths))
	for _, path := range filePaths {
		parts = append(parts, fmt.Sprintf(`POSIX file "%s"`, escapeAppleScriptString(path)))
	}
	return fmt.Sprintf(`tell application "Messages"
  send {%s} to chat id "%s"
end tell`, strings.Join(parts, ", "), escapeAppleScriptString(chatGUID))
}

func escapeAppleScriptString(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, `"`, `\"`)
	return value
}
