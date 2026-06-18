package imessage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type Action string

const (
	ActionEdit    Action = "edit"
	ActionRetract Action = "retract"
	ActionDelete  Action = "delete"
)

type Capabilities struct {
	Edit             bool   `json:"edit"`
	Retract          bool   `json:"retract"`
	Delete           bool   `json:"delete"`
	Available        bool   `json:"available"`
	Helper           string `json:"helper,omitempty"`
	Reason           string `json:"reason,omitempty"`
	RequiresMessages bool   `json:"requiresMessages"`
}

type Request struct {
	Action      Action `json:"action"`
	ChatGUID    string `json:"chatGuid"`
	MessageGUID string `json:"messageGuid"`
	Text        string `json:"text,omitempty"`
	PartIndex   int    `json:"partIndex"`
}

type ActionError struct {
	Code       string
	Message    string
	Retryable  bool
	StatusCode int
}

func (e *ActionError) Error() string { return e.Message }

func ErrorCode(err error) string {
	var actionErr *ActionError
	if errors.As(err, &actionErr) {
		return actionErr.Code
	}
	return "action_failed"
}

func ErrorStatus(err error) int {
	var actionErr *ActionError
	if errors.As(err, &actionErr) && actionErr.StatusCode != 0 {
		return actionErr.StatusCode
	}
	return 500
}

type Performer interface {
	Capabilities(ctx context.Context) Capabilities
	Edit(ctx context.Context, req Request) error
	Retract(ctx context.Context, req Request) error
	Delete(ctx context.Context, req Request) error
}

type HelperPerformer struct {
	Path    string
	Lookup  func() (string, error)
	Runner  func(context.Context, string, helperEnvelope) (helperEnvelope, error)
	Timeout time.Duration
}

type helperEnvelope struct {
	Action       string          `json:"action"`
	ChatGUID     string          `json:"chatGuid,omitempty"`
	MessageGUID  string          `json:"messageGuid,omitempty"`
	Text         string          `json:"text,omitempty"`
	PartIndex    int             `json:"partIndex,omitempty"`
	OK           bool            `json:"ok,omitempty"`
	Error        string          `json:"error,omitempty"`
	Code         string          `json:"code,omitempty"`
	Capabilities map[string]bool `json:"capabilities,omitempty"`
}

func NewHelperPerformer(path string) *HelperPerformer {
	return &HelperPerformer{Path: strings.TrimSpace(path), Timeout: 12 * time.Second}
}

func (p *HelperPerformer) Capabilities(ctx context.Context) Capabilities {
	path, err := p.helperPath()
	if err != nil {
		return Capabilities{
			Available:        false,
			Reason:           err.Error(),
			RequiresMessages: true,
		}
	}
	env, err := p.run(ctx, path, helperEnvelope{Action: "status"})
	if err != nil {
		return Capabilities{
			Available:        false,
			Helper:           path,
			Reason:           err.Error(),
			RequiresMessages: true,
		}
	}
	caps := env.Capabilities
	return Capabilities{
		Available:        true,
		Helper:           path,
		Edit:             caps["edit"],
		Retract:          caps["retract"],
		Delete:           caps["delete"],
		RequiresMessages: true,
	}
}

func (p *HelperPerformer) Edit(ctx context.Context, req Request) error {
	if strings.TrimSpace(req.Text) == "" {
		return &ActionError{Code: "bad_request", Message: "edited text is required", StatusCode: 400}
	}
	return p.perform(ctx, Request{Action: ActionEdit, ChatGUID: req.ChatGUID, MessageGUID: req.MessageGUID, Text: req.Text, PartIndex: req.PartIndex})
}

func (p *HelperPerformer) Retract(ctx context.Context, req Request) error {
	return p.perform(ctx, Request{Action: ActionRetract, ChatGUID: req.ChatGUID, MessageGUID: req.MessageGUID, PartIndex: req.PartIndex})
}

func (p *HelperPerformer) Delete(ctx context.Context, req Request) error {
	return p.perform(ctx, Request{Action: ActionDelete, ChatGUID: req.ChatGUID, MessageGUID: req.MessageGUID})
}

func (p *HelperPerformer) perform(ctx context.Context, req Request) error {
	if strings.TrimSpace(req.ChatGUID) == "" {
		return &ActionError{Code: "bad_request", Message: "chatGuid is required", StatusCode: 400}
	}
	if strings.TrimSpace(req.MessageGUID) == "" {
		return &ActionError{Code: "bad_request", Message: "messageGuid is required", StatusCode: 400}
	}
	path, err := p.helperPath()
	if err != nil {
		return &ActionError{Code: "unsupported", Message: err.Error(), StatusCode: 501}
	}
	env := helperEnvelope{
		Action:      string(req.Action),
		ChatGUID:    req.ChatGUID,
		MessageGUID: req.MessageGUID,
		Text:        req.Text,
		PartIndex:   req.PartIndex,
	}
	resp, err := p.run(ctx, path, env)
	if err != nil {
		return mapHelperError(err.Error())
	}
	if resp.OK {
		return nil
	}
	if resp.Code == "" {
		resp.Code = "action_failed"
	}
	if resp.Error == "" {
		resp.Error = "iMessage action failed"
	}
	return mapHelperErrorCode(resp.Code, resp.Error)
}

func (p *HelperPerformer) helperPath() (string, error) {
	if p.Lookup != nil {
		return p.Lookup()
	}
	if p.Path != "" {
		if isExecutable(p.Path) {
			return p.Path, nil
		}
		return "", fmt.Errorf("MicaGo IMCore helper is not executable: %s", p.Path)
	}
	if env := strings.TrimSpace(os.Getenv("MICAGO_IMCORE_HELPER")); env != "" {
		if isExecutable(env) {
			return env, nil
		}
		return "", fmt.Errorf("MICAGO_IMCORE_HELPER is not executable: %s", env)
	}
	exe, err := os.Executable()
	if err == nil {
		dir := filepath.Dir(exe)
		for _, name := range []string{"micago-imcore-helper", "MicaGoIMCoreHelper"} {
			candidate := filepath.Join(dir, name)
			if isExecutable(candidate) {
				return candidate, nil
			}
		}
		if strings.Contains(dir, ".app/Contents/MacOS") {
			resources := filepath.Clean(filepath.Join(dir, "..", "Resources"))
			for _, name := range []string{"micago-imcore-helper", "MicaGoIMCoreHelper"} {
				candidate := filepath.Join(resources, name)
				if isExecutable(candidate) {
					return candidate, nil
				}
			}
		}
	}
	return "", errors.New("MicaGo IMCore helper is not bundled with this backend build")
}

func (p *HelperPerformer) run(ctx context.Context, path string, env helperEnvelope) (helperEnvelope, error) {
	if p.Runner != nil {
		return p.Runner(ctx, path, env)
	}
	timeout := p.Timeout
	if timeout <= 0 {
		timeout = 12 * time.Second
	}
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	body, err := json.Marshal(env)
	if err != nil {
		return helperEnvelope{}, err
	}
	cmd := exec.CommandContext(runCtx, path)
	cmd.Stdin = bytes.NewReader(body)
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return helperEnvelope{}, errors.New(msg)
	}
	var resp helperEnvelope
	if err := json.Unmarshal(out.Bytes(), &resp); err != nil {
		return helperEnvelope{}, fmt.Errorf("decode helper response: %w", err)
	}
	return resp, nil
}

func isExecutable(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	return info.Mode()&0o111 != 0
}

func mapHelperError(msg string) error {
	lower := strings.ToLower(msg)
	switch {
	case strings.Contains(lower, "not available"), strings.Contains(lower, "selector"), strings.Contains(lower, "not supported"):
		return mapHelperErrorCode("unsupported", msg)
	case strings.Contains(lower, "expired"), strings.Contains(lower, "too old"):
		return mapHelperErrorCode("expired", msg)
	case strings.Contains(lower, "not allowed"), strings.Contains(lower, "permission"):
		return mapHelperErrorCode("not_allowed", msg)
	case strings.Contains(lower, "not found"):
		return mapHelperErrorCode("not_found", msg)
	default:
		return mapHelperErrorCode("action_failed", msg)
	}
}

func mapHelperErrorCode(code, msg string) error {
	status := 500
	switch code {
	case "bad_request":
		status = 400
	case "not_allowed", "expired":
		status = 409
	case "not_found":
		status = 404
	case "unsupported":
		status = 501
	}
	return &ActionError{Code: code, Message: msg, StatusCode: status}
}
