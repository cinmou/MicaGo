package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadGeneratesConfigAndToken(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cfg, err := Load(Options{})
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.FirstRun {
		t.Fatal("expected first run config generation")
	}
	if len(cfg.AuthToken) < 64 {
		t.Fatalf("expected generated token, got %q", cfg.AuthToken)
	}

	body, err := os.ReadFile(filepath.Join(home, ".micago", "config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "token:") {
		t.Fatalf("expected token in config file, got %s", string(body))
	}
}

func TestValidateSecurityRejectsDisableAuthOnNonLocalAddress(t *testing.T) {
	err := ValidateSecurity(Config{
		HTTPAddr:     "0.0.0.0:3000",
		AuthDisabled: true,
	})
	if err == nil {
		t.Fatal("expected disable-auth validation error")
	}
}
