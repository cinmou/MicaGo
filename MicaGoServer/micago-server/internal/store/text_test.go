package store

import (
	"testing"

	micasend "micagoserver/internal/send"
)

func TestExtractMessageTextPrefersMessageText(t *testing.T) {
	text := "  hello from text  "
	extracted := ExtractMessageText(&text, syntheticAttributedBody("ignored"))
	if extracted == nil {
		t.Fatal("expected extracted text")
	}
	if *extracted != "  hello from text  " {
		t.Fatalf("expected trimmed text, got %q", *extracted)
	}
}

func TestExtractMessageTextFallsBackToAttributedBody(t *testing.T) {
	extracted := ExtractMessageText(nil, syntheticAttributedBody("hello from attributed body"))
	if extracted == nil {
		t.Fatal("expected extracted attributedBody text")
	}
	if *extracted != "hello from attributed body" {
		t.Fatalf("unexpected extracted text %q", *extracted)
	}
}

func TestExtractMessageTextFallsBackToAttributedBodyEmoji(t *testing.T) {
	extracted := ExtractMessageText(nil, syntheticAttributedBody("😊"))
	if extracted == nil {
		t.Fatal("expected extracted attributedBody emoji")
	}
	if *extracted != "😊" {
		t.Fatalf("unexpected extracted text %q", *extracted)
	}
}

func TestMessageHasRenderableContentWithAttributedBodyText(t *testing.T) {
	extracted := ExtractMessageText(nil, syntheticAttributedBody("sent from applescript"))
	if !MessageHasRenderableContent(extracted, false) {
		t.Fatal("expected attributedBody-backed message to pass clean filter")
	}
}

func TestRowToMessageJSONUsesAttributedBodyTextForMatching(t *testing.T) {
	message := rowToMessageJSON(MessageRow{
		GUID:           "msg-1",
		AttributedBody: syntheticAttributedBody("Hello World"),
	})

	if message.Text == nil {
		t.Fatal("expected text from attributedBody")
	}
	if normalized := micasend.NormalizeText(*message.Text); normalized != "helloworld" {
		t.Fatalf("unexpected normalized text %q", normalized)
	}
}

func syntheticAttributedBody(text string) []byte {
	prefix := []byte{
		0x04, 0x0b, 's', 't', 'r', 'e', 'a', 'm', 't', 'y', 'p', 'e',
		0x81, 0xe8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12,
		'N', 'S', 'A', 't', 't', 'r', 'i', 'b', 'u', 't', 'e', 'd', 'S', 't', 'r', 'i', 'n', 'g',
		0x00, 0x84, 0x84, 0x08, 'N', 'S', 'O', 'b', 'j', 'e', 'c', 't', 0x00,
		0x85, 0x92, 0x84, 0x84, 0x84, 0x08, 'N', 'S', 'S', 't', 'r', 'i', 'n', 'g',
		0x01, 0x94, 0x84, 0x01, 0x2b, byte(len([]byte(text))),
	}
	suffix := []byte{0x86, 0x84, 0x02, 'i', 'I', 0x94, 0x01, 0x02, 0x92, 0x84, 0x84, 0x84, 0x0c, 'N', 'S', 'D', 'i', 'c', 't'}
	return append(append(prefix, []byte(text)...), suffix...)
}
