package store

import "testing"

func sp(s string) *string { return &s }

func TestAttachmentKindInference(t *testing.T) {
	cases := []struct {
		name         string
		isSticker    bool
		mimeType     *string
		uti          *string
		transferName *string
		filename     *string
		wantKind     string
		wantVoice    bool
		wantMime     string // expected effective mime ("" => nil)
	}{
		{
			name:     "image by mime",
			mimeType: sp("image/jpeg"),
			uti:      sp("public.jpeg"),
			wantKind: AttachmentKindImage,
			wantMime: "image/jpeg",
		},
		{
			name:     "heic by uti only (mime inferred)",
			uti:      sp("public.heic"),
			wantKind: AttachmentKindImage,
			wantMime: "image/heic",
		},
		{
			name:         "pdf file by mime",
			mimeType:     sp("application/pdf"),
			transferName: sp("invoice.pdf"),
			wantKind:     AttachmentKindFile,
			wantMime:     "application/pdf",
		},
		{
			name:         "pdf file by extension only",
			transferName: sp("report.PDF"),
			wantKind:     AttachmentKindFile,
			wantMime:     "application/pdf",
		},
		{
			name:      "voice message by caf uti",
			uti:       sp("com.apple.coreaudio-format"),
			wantKind:  AttachmentKindAudio,
			wantVoice: true,
			wantMime:  "audio/x-caf",
		},
		{
			name:      "regular audio mp3 is not a voice message",
			mimeType:  sp("audio/mpeg"),
			uti:       sp("public.mp3"),
			wantKind:  AttachmentKindAudio,
			wantVoice: false,
			wantMime:  "audio/mpeg",
		},
		{
			name:     "video by mime",
			mimeType: sp("video/quicktime"),
			uti:      sp("com.apple.quicktime-movie"),
			wantKind: AttachmentKindVideo,
			wantMime: "video/quicktime",
		},
		{
			name:         "video by extension only",
			transferName: sp("clip.mov"),
			wantKind:     AttachmentKindVideo,
			wantMime:     "video/quicktime",
		},
		{
			name:      "sticker wins over mime",
			isSticker: true,
			mimeType:  sp("image/png"),
			uti:       sp("public.png"),
			wantKind:  AttachmentKindSticker,
			wantMime:  "image/png",
		},
		{
			name:     "unknown when nothing identifies it",
			wantKind: AttachmentKindUnknown,
			wantMime: "",
		},
		{
			name:         "opaque type with name is a file",
			transferName: sp("data.unknownext"),
			wantKind:     AttachmentKindFile,
			wantMime:     "", // nothing maps this extension
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotKind := AttachmentKind(tc.isSticker, tc.mimeType, tc.uti, tc.transferName, tc.filename)
			if gotKind != tc.wantKind {
				t.Errorf("AttachmentKind = %q, want %q", gotKind, tc.wantKind)
			}

			gotVoice := IsVoiceMessage(tc.uti, tc.mimeType)
			if gotVoice != tc.wantVoice {
				t.Errorf("IsVoiceMessage = %v, want %v", gotVoice, tc.wantVoice)
			}

			gotMime := InferMimeType(tc.mimeType, tc.uti, tc.transferName, tc.filename)
			if tc.wantMime == "" {
				if gotMime != nil {
					t.Errorf("InferMimeType = %q, want nil", *gotMime)
				}
			} else if gotMime == nil || *gotMime != tc.wantMime {
				t.Errorf("InferMimeType = %v, want %q", gotMime, tc.wantMime)
			}
		})
	}
}

func TestInferMimeTypePreservesStoredMime(t *testing.T) {
	stored := sp("application/x-weird")
	got := InferMimeType(stored, sp("public.jpeg"), sp("photo.jpg"), nil)
	if got == nil || *got != "application/x-weird" {
		t.Fatalf("expected stored mime preserved, got %v", got)
	}
}

func TestInferMimeTypeFromUTI(t *testing.T) {
	got := InferMimeType(nil, sp("com.adobe.pdf"), nil, nil)
	if got == nil || *got != "application/pdf" {
		t.Fatalf("expected application/pdf from uti, got %v", got)
	}
}

func TestInferMimeTypeFromExtension(t *testing.T) {
	got := InferMimeType(nil, nil, sp("voice.caf"), nil)
	if got == nil || *got != "audio/x-caf" {
		t.Fatalf("expected audio/x-caf from extension, got %v", got)
	}
}

func TestInferMimeTypeNilWhenUnknown(t *testing.T) {
	if got := InferMimeType(nil, nil, nil, nil); got != nil {
		t.Fatalf("expected nil mime, got %v", *got)
	}
}

func TestDecorateAttachmentJSONFillsDerivedFields(t *testing.T) {
	a := AttachmentJSON{Uti: sp("com.apple.coreaudio-format")}
	DecorateAttachmentJSON(&a)
	if a.AttachmentKind != AttachmentKindAudio {
		t.Errorf("kind = %q, want audio", a.AttachmentKind)
	}
	if !a.IsVoiceMessage {
		t.Error("expected IsVoiceMessage true for caf uti")
	}
	if a.MimeType == nil || *a.MimeType != "audio/x-caf" {
		t.Errorf("mime = %v, want audio/x-caf", a.MimeType)
	}
}
