package httpapi

import (
	"os"
	"path/filepath"
	"testing"
)

// C39: stickers live in ~/Library/Messages/StickerCache (a sibling of
// Attachments). The path guard must allow that sibling so the PNG can be served,
// while still rejecting anything outside those two Messages subdirectories.
func TestResolveAttachmentPathAllowsStickerCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	msgs := filepath.Join(home, "Library", "Messages")
	attach := filepath.Join(msgs, "Attachments")
	stickerDir := filepath.Join(msgs, "StickerCache", "abc")
	if err := os.MkdirAll(attach, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(stickerDir, 0o700); err != nil {
		t.Fatal(err)
	}
	stickerFile := filepath.Join(stickerDir, "s.png")
	if err := os.WriteFile(stickerFile, []byte("png-bytes"), 0o600); err != nil {
		t.Fatal(err)
	}

	// A sticker referenced by its StickerCache path is served.
	lp := "~/Library/Messages/StickerCache/abc/s.png"
	got, ok := resolveAttachmentPath(attach, &lp)
	if !ok {
		t.Fatal("StickerCache path was rejected; expected it to be allowed")
	}
	want, _ := filepath.EvalSymlinks(stickerFile)
	if got != want {
		t.Fatalf("resolved %q, want %q", got, want)
	}

	// A regular attachment under Attachments still works.
	att := filepath.Join(attach, "p.jpg")
	if err := os.WriteFile(att, []byte("jpg"), 0o600); err != nil {
		t.Fatal(err)
	}
	ap := "~/Library/Messages/Attachments/p.jpg"
	if _, ok := resolveAttachmentPath(attach, &ap); !ok {
		t.Fatal("normal attachment path rejected")
	}

	// Anything outside both roots stays rejected (the security guard holds).
	outside := filepath.Join(home, "secret.txt")
	if err := os.WriteFile(outside, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	op := "~/secret.txt"
	if _, ok := resolveAttachmentPath(attach, &op); ok {
		t.Fatal("path outside Attachments/StickerCache must be rejected")
	}
}
