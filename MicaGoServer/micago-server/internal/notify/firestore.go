package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// FirestoreURLSync writes ONLY the public base URL to a single Firestore
// document so remote clients can rediscover a changed tunnel URL. It never
// writes tokens, message content, contacts, or any other data. Optional.
type FirestoreURLSync struct {
	projectID  string
	collection string
	document   string
	tokens     tokenProvider
	client     *http.Client
}

func NewFirestoreURLSync(projectID, collection, document string, tokens tokenProvider, client *http.Client) *FirestoreURLSync {
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	if collection == "" {
		collection = "server"
	}
	if document == "" {
		document = "config"
	}
	return &FirestoreURLSync{projectID: projectID, collection: collection, document: document, tokens: tokens, client: client}
}

// SetPublicURL upserts `{ publicBaseUrl: <url> }` into the configured document.
func (f *FirestoreURLSync) SetPublicURL(ctx context.Context, publicURL string) error {
	accessToken, err := f.tokens.Token(ctx)
	if err != nil {
		return fmt.Errorf("firestore token: %w", err)
	}
	endpoint := fmt.Sprintf(
		"https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s?updateMask.fieldPaths=publicBaseUrl",
		f.projectID, f.collection, f.document)

	doc := map[string]any{
		"fields": map[string]any{
			"publicBaseUrl": map[string]any{"stringValue": publicURL},
		},
	}
	body, err := json.Marshal(doc)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPatch, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := f.client.Do(req)
	if err != nil {
		return fmt.Errorf("firestore write: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<14))
		return fmt.Errorf("firestore write failed: HTTP %d: %s", resp.StatusCode, string(msg))
	}
	return nil
}
