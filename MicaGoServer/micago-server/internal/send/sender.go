package send

import "context"

type Sender interface {
	SendText(ctx context.Context, chatGUID, message string) error
}
