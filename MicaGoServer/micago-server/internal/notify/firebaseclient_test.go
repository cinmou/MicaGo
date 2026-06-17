package notify

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadFirebaseClientConfigParsesGoogleServices(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "google-services.json")
	content := `{
      "project_info": {
        "project_number": "1234567890",
        "project_id": "micago-demo",
        "storage_bucket": "micago-demo.appspot.com"
      },
      "client": [
        {
          "client_info": { "mobilesdk_app_id": "1:1234567890:android:abcdef" },
          "api_key": [ { "current_key": "AIzaSyFAKEKEY" } ]
        }
      ]
    }`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadFirebaseClientConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Configured || cfg.ProjectID != "micago-demo" || cfg.APIKey != "AIzaSyFAKEKEY" ||
		cfg.AppID != "1:1234567890:android:abcdef" || cfg.MessagingSenderID != "1234567890" ||
		cfg.StorageBucket != "micago-demo.appspot.com" {
		t.Fatalf("unexpected parsed config: %#v", cfg)
	}
}

func TestLoadFirebaseClientConfigUnconfiguredWhenEmpty(t *testing.T) {
	cfg, err := LoadFirebaseClientConfig("")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Configured {
		t.Fatal("expected unconfigured when no path is set")
	}
}
