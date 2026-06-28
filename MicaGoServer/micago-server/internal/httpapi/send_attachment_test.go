package httpapi

import (
	"bytes"
	"context"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"micagoserver/internal/config"
	"micagoserver/internal/relaydb"
	"micagoserver/internal/store"
)

// smsChatQueries returns a non-iMessage chat so the attachment gate can be
// exercised. It embeds stubQueries and only overrides GetChatInfo.
type smsChatQueries struct{ stubQueries }

func (s *smsChatQueries) GetChatInfo(_ context.Context, guid string) (*store.ChatInfo, error) {
	svc := "SMS"
	return &store.ChatInfo{GUID: guid, ServiceName: &svc}, nil
}

type recordingAttachmentSender struct {
	noopSender
	path string
}

func (s *recordingAttachmentSender) SendAttachment(_ context.Context, _ string, path string) error {
	s.path = path
	return nil
}

func multipartFile(t *testing.T, field, filename string, data []byte) (*bytes.Buffer, string) {
	t.Helper()
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	fw, err := w.CreateFormFile(field, filename)
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	if _, err := fw.Write(data); err != nil {
		t.Fatalf("write: %v", err)
	}
	_ = w.WriteField("tempGuid", "tmp-1")
	if err := w.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	return &buf, w.FormDataContentType()
}

// C19: attachments are sendable only to iMessage chats — SMS/RCS/unknown are
// read-only on the client and must be rejected server-side too.
func TestSendAttachmentRejectsNonIMessageChat(t *testing.T) {
	handlers := NewHandlers(
		&smsChatQueries{}, log.New(io.Discard, "", 0),
		&SendDependencies{Sender: noopSender{}}, nil, t.TempDir(),
		&stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{},
	)

	body, contentType := multipartFile(t, "file", "photo.jpg", []byte("jpegbytes"))
	req := httptest.NewRequest(http.MethodPost, "/api/chats/c1/send-attachment", body)
	req.Header.Set("Content-Type", contentType)
	req.SetPathValue("guid", "c1")
	rec := httptest.NewRecorder()

	handlers.SendAttachment(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for SMS chat, got %d (%s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "iMessage") {
		t.Fatalf("body should explain iMessage-only: %s", rec.Body.String())
	}
}

// A well-formed upload to an iMessage chat sends via the (stub) sender and is
// accepted optimistically.
func TestSendAttachmentAcceptsIMessageUpload(t *testing.T) {
	root := t.TempDir()
	home := t.TempDir()
	t.Setenv("HOME", home)
	sender := &recordingAttachmentSender{}
	handlers := NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0), // stubQueries.GetChatInfo → iMessage
		&SendDependencies{Sender: sender}, nil, root,
		&stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{},
	)

	body, contentType := multipartFile(t, "file", "photo.jpg", []byte("jpegbytes"))
	req := httptest.NewRequest(http.MethodPost, "/api/chats/c1/send-attachment", body)
	req.Header.Set("Content-Type", contentType)
	req.SetPathValue("guid", "c1")
	rec := httptest.NewRecorder()

	handlers.SendAttachment(rec, req)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "photo.jpg") {
		t.Fatalf("response should echo filename: %s", rec.Body.String())
	}
	wantPrefix := filepath.Join(home, "Library", "Messages", "Attachments", "MicaGo", "Outgoing")
	if !strings.HasPrefix(sender.path, wantPrefix) {
		t.Fatalf("attachment should be staged under Messages attachments; got %q want prefix %q", sender.path, wantPrefix)
	}
	if !strings.HasSuffix(sender.path, "photo.jpg") {
		t.Fatalf("attachment should preserve filename, got %q", sender.path)
	}
}

// A failing sender surfaces a 500 and does not leave the temp file behind.
func TestSendAttachmentReportsSenderFailure(t *testing.T) {
	handlers := NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0),
		&SendDependencies{Sender: errorSender{}}, nil, t.TempDir(),
		&stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{},
	)

	body, contentType := multipartFile(t, "file", "doc.pdf", []byte("pdfbytes"))
	req := httptest.NewRequest(http.MethodPost, "/api/chats/c1/send-attachment", body)
	req.Header.Set("Content-Type", contentType)
	req.SetPathValue("guid", "c1")
	rec := httptest.NewRecorder()

	handlers.SendAttachment(rec, req)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d (%s)", rec.Code, rec.Body.String())
	}
}

// Missing file field → 400 (not a crash).
func TestSendAttachmentRequiresFile(t *testing.T) {
	handlers := NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0),
		&SendDependencies{Sender: noopSender{}}, nil, t.TempDir(),
		&stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{},
	)
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	_ = w.WriteField("tempGuid", "tmp-1")
	_ = w.Close()
	req := httptest.NewRequest(http.MethodPost, "/api/chats/c1/send-attachment", &buf)
	req.Header.Set("Content-Type", w.FormDataContentType())
	req.SetPathValue("guid", "c1")
	rec := httptest.NewRecorder()

	handlers.SendAttachment(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for missing file, got %d", rec.Code)
	}
}

func TestVoiceAttachmentHelpers(t *testing.T) {
	if !parseBoolFormValue("true") || !parseBoolFormValue("1") || !parseBoolFormValue("on") {
		t.Fatal("expected common true form values")
	}
	if parseBoolFormValue("false") || parseBoolFormValue("") {
		t.Fatal("expected false form values")
	}
	if !isMicaGoVoiceUpload("voice_1782663292267.m4a") {
		t.Fatal("expected MicaGo voice upload filename")
	}
	if isMicaGoVoiceUpload("song.m4a") {
		t.Fatal("ordinary m4a must not be treated as voice upload")
	}
}

// stubSyncSettings lets tests flip AllowSMSSend.
type stubSyncSettings struct{ allowSMS bool }

func (s stubSyncSettings) GetSyncSettings(context.Context) (relaydb.SyncSettings, error) {
	st := relaydb.DefaultSyncSettings()
	st.AllowSMSSend = s.allowSMS
	return st, nil
}
func (s stubSyncSettings) SetSyncSettings(_ context.Context, in relaydb.SyncSettings) (relaydb.SyncSettings, error) {
	return in, nil
}

// C20: SMS attachment send is rejected when AllowSMSSend is off, accepted when on.
func TestSendAttachmentSMSGate(t *testing.T) {
	newH := func(allow bool) *Handlers {
		h := NewHandlers(
			&smsChatQueries{}, log.New(io.Discard, "", 0),
			&SendDependencies{Sender: noopSender{}}, nil, t.TempDir(),
			&stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{},
		)
		h.SetSyncSettingsService(stubSyncSettings{allowSMS: allow})
		return h
	}

	// Off → 400.
	body, ct := multipartFile(t, "file", "p.jpg", []byte("x"))
	req := httptest.NewRequest(http.MethodPost, "/api/chats/c1/send-attachment", body)
	req.Header.Set("Content-Type", ct)
	req.SetPathValue("guid", "c1")
	rec := httptest.NewRecorder()
	newH(false).SendAttachment(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("SMS off: expected 400, got %d", rec.Code)
	}

	// On → 202.
	body2, ct2 := multipartFile(t, "file", "p.jpg", []byte("x"))
	req2 := httptest.NewRequest(http.MethodPost, "/api/chats/c1/send-attachment", body2)
	req2.Header.Set("Content-Type", ct2)
	req2.SetPathValue("guid", "c1")
	rec2 := httptest.NewRecorder()
	newH(true).SendAttachment(rec2, req2)
	if rec2.Code != http.StatusAccepted {
		t.Fatalf("SMS on: expected 202, got %d (%s)", rec2.Code, rec2.Body.String())
	}
}
