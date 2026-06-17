package send

import "context"

type Sender interface {
	SendText(ctx context.Context, chatGUID, message string) error
	// SendAttachment sends a local file to the chat via Messages. filePath must
	// be an absolute path readable by the user running the server (C19).
	SendAttachment(ctx context.Context, chatGUID, filePath string) error
}
