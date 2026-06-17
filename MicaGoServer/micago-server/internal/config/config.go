package config

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	defaultAddr             = "127.0.0.1:3000"
	defaultSyncInterval     = 5 * time.Second
	defaultInitialSyncLimit = 1000
	defaultNotificationProv = "none"
	defaultNotificationPrev = "sender"
	tokenBytes              = 32
	defaultPreferredPairing = "auto"
	defaultUpdateLookback   = 168 * time.Hour // 7 days
)

// ValidPairingPreferences lists the accepted values for
// network.preferred_pairing_endpoint. "auto" lets the client/companion choose;
// the others express a default preference, not a server-wide mode.
var ValidPairingPreferences = []string{"auto", "local", "lan", "public"}

type Options struct {
	Addr            string
	Token           string
	DisableAuth     bool
	PublicURL       string
	SyncInterval    string
	DisableSyncLoop bool
	SyncOnce        bool
}

type Config struct {
	ConfigPath      string
	DBPath          string
	RelayDBPath     string
	AttachmentsRoot string
	HTTPAddr        string
	PublicURL       string
	AuthToken       string
	// Network / connection-endpoint settings (v0.11). Local + LAN endpoints are
	// always derived from HTTPAddr; PublicBaseURL is an optional EXTRA endpoint,
	// never a replacement for local/LAN.
	PublicBaseURL            string
	VerifyTLS                bool
	PreferredPairingEndpoint string
	AuthDisabled             bool
	InitialSyncLimit         int
	SyncInterval             time.Duration
	UpdateLookback           time.Duration
	DisableSyncLoop          bool
	SyncOnce                 bool
	NotificationsEnabled     bool
	NotificationProvider     string
	NotificationPreview      string
	WebhookURL               string
	FCM                      FCMConfig
	HMS                      HMSConfig
	Firebase                 FirebaseConfig
	FirstRun                 bool
}

type FCMConfig struct {
	Enabled            bool
	ProjectID          string
	ServiceAccountPath string
	// GoogleServicesPath points at the user's own google-services.json (C22).
	// The server parses its client config (api key, app id, sender id, storage
	// bucket) and serves it at GET /api/fcm/client so the Flutter app can
	// initialize Firebase at runtime — no config baked into the APK, fully
	// optional, BlueBubbles-style user-owned Firebase.
	GoogleServicesPath string
}

// FirebaseConfig controls the optional Firestore public-URL sync (v0.12). It
// reuses the FCM service account/project for credentials. Off by default.
type FirebaseConfig struct {
	PublicURLSync bool
	URLCollection string
	URLDocument   string
}

type HMSConfig struct {
	Enabled        bool
	AppID          string
	AppSecret      string
	TokenCachePath string
}

type fileConfig struct {
	Server struct {
		Addr      string
		PublicURL string
	}
	Network struct {
		PublicBaseURL            string
		VerifyTLS                bool
		PreferredPairingEndpoint string
	}
	Auth struct {
		Token string
	}
	Sync struct {
		Interval       string
		UpdateLookback string
	}
	Notifications struct {
		Enabled  bool
		Provider string
		Preview  string
	}
	Webhook struct {
		URL string
	}
	FCM struct {
		Enabled            bool
		ProjectID          string
		ServiceAccountPath string
		GoogleServicesPath string
	}
	HMS struct {
		Enabled        bool
		AppID          string
		AppSecret      string
		TokenCachePath string
	}
	Firebase struct {
		PublicURLSync bool
		URLCollection string
		URLDocument   string
	}
}

func Load(opts Options) (Config, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Config{}, fmt.Errorf("resolve home directory: %w", err)
	}

	baseDir := filepath.Join(home, ".micago")
	cfgPath := filepath.Join(baseDir, "config.yaml")
	firstRun, fileCfg, err := ensureConfigFile(baseDir, cfgPath)
	if err != nil {
		return Config{}, err
	}

	syncInterval := defaultSyncInterval
	if strings.TrimSpace(fileCfg.Sync.Interval) != "" {
		syncInterval, err = time.ParseDuration(strings.TrimSpace(fileCfg.Sync.Interval))
		if err != nil {
			return Config{}, fmt.Errorf("parse sync.interval: %w", err)
		}
	}
	if strings.TrimSpace(opts.SyncInterval) != "" {
		syncInterval, err = time.ParseDuration(strings.TrimSpace(opts.SyncInterval))
		if err != nil {
			return Config{}, fmt.Errorf("parse --sync-interval: %w", err)
		}
	}

	// Lookback window for the v0.11.x update pass. Empty -> default; "0" disables.
	updateLookback := defaultUpdateLookback
	if raw := strings.TrimSpace(fileCfg.Sync.UpdateLookback); raw != "" {
		updateLookback, err = time.ParseDuration(raw)
		if err != nil {
			return Config{}, fmt.Errorf("parse sync.update_lookback: %w", err)
		}
		if updateLookback < 0 {
			return Config{}, fmt.Errorf("sync.update_lookback must not be negative")
		}
	}

	cfg := Config{
		ConfigPath:      cfgPath,
		DBPath:          filepath.Join(home, "Library", "Messages", "chat.db"),
		RelayDBPath:     filepath.Join(baseDir, "relay.db"),
		AttachmentsRoot: filepath.Join(home, "Library", "Messages", "Attachments"),
		HTTPAddr:        valueOrDefault(opts.Addr, fileCfg.Server.Addr, defaultAddr),
		PublicURL:       valueOrDefault(opts.PublicURL, fileCfg.Server.PublicURL, ""),
		// network.public_base_url is the canonical public endpoint; fall back to
		// the legacy server.public_url (and --public-url flag) when unset.
		PublicBaseURL:            valueOrDefault(opts.PublicURL, fileCfg.Network.PublicBaseURL, fileCfg.Server.PublicURL),
		VerifyTLS:                fileCfg.Network.VerifyTLS,
		PreferredPairingEndpoint: valueOrDefault("", fileCfg.Network.PreferredPairingEndpoint, defaultPreferredPairing),
		AuthToken:                valueOrDefault(opts.Token, fileCfg.Auth.Token, ""),
		AuthDisabled:             opts.DisableAuth,
		InitialSyncLimit:         defaultInitialSyncLimit,
		SyncInterval:             syncInterval,
		UpdateLookback:           updateLookback,
		DisableSyncLoop:          opts.DisableSyncLoop,
		SyncOnce:                 opts.SyncOnce,
		NotificationsEnabled:     fileCfg.Notifications.Enabled,
		NotificationProvider:     valueOrDefault("", fileCfg.Notifications.Provider, defaultNotificationProv),
		NotificationPreview:      valueOrDefault("", fileCfg.Notifications.Preview, defaultNotificationPrev),
		WebhookURL:               fileCfg.Webhook.URL,
		FCM: FCMConfig{
			Enabled:            fileCfg.FCM.Enabled,
			ProjectID:          fileCfg.FCM.ProjectID,
			ServiceAccountPath: expandPath(home, fileCfg.FCM.ServiceAccountPath),
			GoogleServicesPath: expandPath(home, fileCfg.FCM.GoogleServicesPath),
		},
		HMS: HMSConfig{
			Enabled:        fileCfg.HMS.Enabled,
			AppID:          fileCfg.HMS.AppID,
			AppSecret:      fileCfg.HMS.AppSecret,
			TokenCachePath: expandPath(home, valueOrDefault("", fileCfg.HMS.TokenCachePath, "~/.micago/hms-token.json")),
		},
		Firebase: FirebaseConfig{
			PublicURLSync: fileCfg.Firebase.PublicURLSync,
			URLCollection: valueOrDefault("", fileCfg.Firebase.URLCollection, "server"),
			URLDocument:   valueOrDefault("", fileCfg.Firebase.URLDocument, "config"),
		},
		FirstRun: firstRun,
	}

	if cfg.AuthToken == "" && !cfg.AuthDisabled {
		return Config{}, errors.New("auth token is empty")
	}
	if cfg.NotificationPreview != "none" && cfg.NotificationPreview != "sender" && cfg.NotificationPreview != "sender_and_text" {
		return Config{}, fmt.Errorf("invalid notifications.preview %q", cfg.NotificationPreview)
	}
	if cfg.NotificationProvider == "" {
		cfg.NotificationProvider = defaultNotificationProv
	}
	if !isValidPairingPreference(cfg.PreferredPairingEndpoint) {
		return Config{}, fmt.Errorf("invalid network.preferred_pairing_endpoint %q (want one of auto, local, lan, public)", cfg.PreferredPairingEndpoint)
	}
	if strings.TrimSpace(cfg.PublicBaseURL) != "" {
		if err := ValidatePublicBaseURL(cfg.PublicBaseURL); err != nil {
			return Config{}, err
		}
	}

	return cfg, nil
}

func isValidPairingPreference(v string) bool {
	for _, candidate := range ValidPairingPreferences {
		if v == candidate {
			return true
		}
	}
	return false
}

// ValidatePublicBaseURL checks that a public base URL is a well-formed http(s)
// URL with a host and no path/query/fragment. An empty string is allowed by
// callers (means "no public endpoint"); this function assumes non-empty.
func ValidatePublicBaseURL(raw string) error {
	trimmed := strings.TrimSpace(raw)
	u, err := url.Parse(trimmed)
	if err != nil {
		return fmt.Errorf("invalid public_base_url: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return errors.New("public_base_url must start with http:// or https://")
	}
	if u.Host == "" {
		return errors.New("public_base_url must include a host")
	}
	if (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("public_base_url must be a bare origin (no path, query, or fragment)")
	}
	return nil
}

// UpdatePublicBaseURL rewrites only the network section of the config file at
// cfgPath, preserving all other settings. An empty publicBaseURL clears the
// public endpoint. The file is written with 0600 permissions.
func UpdatePublicBaseURL(cfgPath, publicBaseURL string, verifyTLS bool, preferredPairing string) error {
	trimmed := strings.TrimSpace(publicBaseURL)
	if trimmed != "" {
		if err := ValidatePublicBaseURL(trimmed); err != nil {
			return err
		}
	}
	if preferredPairing == "" {
		preferredPairing = defaultPreferredPairing
	}
	if !isValidPairingPreference(preferredPairing) {
		return fmt.Errorf("invalid preferred_pairing_endpoint %q", preferredPairing)
	}

	body, err := os.ReadFile(cfgPath)
	if err != nil {
		return fmt.Errorf("read config file: %w", err)
	}
	fileCfg, err := parseConfig(string(body))
	if err != nil {
		return err
	}
	fileCfg.Network.PublicBaseURL = trimmed
	fileCfg.Network.VerifyTLS = verifyTLS
	fileCfg.Network.PreferredPairingEndpoint = preferredPairing
	if err := os.WriteFile(cfgPath, []byte(renderConfig(fileCfg)), 0o600); err != nil {
		return fmt.Errorf("write config file: %w", err)
	}
	return nil
}

// NotificationsUpdate carries the notification/FCM/Firebase settings written by
// the companion via POST /api/server/notifications (v0.12). It never carries the
// service-account contents — only a path to the JSON file on the Mac.
type NotificationsUpdate struct {
	Enabled            bool
	Provider           string
	Preview            string
	FCMEnabled         bool
	FCMProjectID       string
	ServiceAccountPath string
	PublicURLSync      bool
}

// UpdateNotificationsConfig persists notification/FCM/Firebase settings, leaving
// all other config untouched. Validates the preview level and provider name.
func UpdateNotificationsConfig(cfgPath string, u NotificationsUpdate) error {
	if u.Preview != "none" && u.Preview != "sender" && u.Preview != "sender_and_text" {
		return fmt.Errorf("invalid notifications.preview %q", u.Preview)
	}
	switch u.Provider {
	case "none", "webhook", "fcm", "hms", "harmony_push", "ntfy":
	default:
		return fmt.Errorf("invalid notifications.provider %q", u.Provider)
	}

	body, err := os.ReadFile(cfgPath)
	if err != nil {
		return fmt.Errorf("read config file: %w", err)
	}
	fileCfg, err := parseConfig(string(body))
	if err != nil {
		return err
	}
	fileCfg.Notifications.Enabled = u.Enabled
	fileCfg.Notifications.Provider = u.Provider
	fileCfg.Notifications.Preview = u.Preview
	fileCfg.FCM.Enabled = u.FCMEnabled
	fileCfg.FCM.ProjectID = strings.TrimSpace(u.FCMProjectID)
	fileCfg.FCM.ServiceAccountPath = strings.TrimSpace(u.ServiceAccountPath)
	fileCfg.Firebase.PublicURLSync = u.PublicURLSync
	if err := os.WriteFile(cfgPath, []byte(renderConfig(fileCfg)), 0o600); err != nil {
		return fmt.Errorf("write config file: %w", err)
	}
	return nil
}

func ValidateSecurity(cfg Config) error {
	if cfg.AuthDisabled && !IsLocalAddress(cfg.HTTPAddr) {
		return errors.New("--disable-auth can only be used with localhost, 127.0.0.1, or ::1")
	}
	return nil
}

func IsLocalAddress(addr string) bool {
	host := addrHost(addr)
	switch strings.ToLower(host) {
	case "", "localhost", "127.0.0.1", "::1":
		return true
	default:
		return false
	}
}

func IsWildcardAddress(addr string) bool {
	host := addrHost(addr)
	return host == "0.0.0.0" || host == "::"
}

func DeriveBaseURL(cfg Config) string {
	if strings.TrimSpace(cfg.PublicURL) != "" {
		return strings.TrimRight(strings.TrimSpace(cfg.PublicURL), "/")
	}
	if cfg.HTTPAddr == "" {
		return ""
	}
	return "http://" + cfg.HTTPAddr
}

func DeriveWebSocketURL(cfg Config) string {
	return WebSocketURLFromBase(DeriveBaseURL(cfg))
}

// WebSocketURLFromBase converts an http(s) base origin into its ws(s) /ws URL.
// Returns "" if base is empty or unparseable.
func WebSocketURLFromBase(base string) string {
	if strings.TrimSpace(base) == "" {
		return ""
	}
	u, err := url.Parse(base)
	if err != nil {
		return ""
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	default:
		u.Scheme = "ws"
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/ws"
	return u.String()
}

func ensureConfigFile(baseDir, cfgPath string) (bool, fileConfig, error) {
	if err := os.MkdirAll(baseDir, 0o700); err != nil {
		return false, fileConfig{}, fmt.Errorf("create config directory: %w", err)
	}

	if _, err := os.Stat(cfgPath); errors.Is(err, os.ErrNotExist) {
		token, err := generateToken()
		if err != nil {
			return false, fileConfig{}, fmt.Errorf("generate auth token: %w", err)
		}
		cfg := defaultFileConfig(token)
		if err := os.WriteFile(cfgPath, []byte(renderConfig(cfg)), 0o600); err != nil {
			return false, fileConfig{}, fmt.Errorf("write config file: %w", err)
		}
		return true, cfg, nil
	} else if err != nil {
		return false, fileConfig{}, fmt.Errorf("stat config file: %w", err)
	}

	body, err := os.ReadFile(cfgPath)
	if err != nil {
		return false, fileConfig{}, fmt.Errorf("read config file: %w", err)
	}
	cfg, err := parseConfig(string(body))
	if err != nil {
		return false, fileConfig{}, err
	}
	return false, cfg, nil
}

func defaultFileConfig(token string) fileConfig {
	var cfg fileConfig
	cfg.Server.Addr = defaultAddr
	cfg.Server.PublicURL = ""
	cfg.Network.PublicBaseURL = ""
	cfg.Network.VerifyTLS = true
	cfg.Network.PreferredPairingEndpoint = defaultPreferredPairing
	cfg.Auth.Token = token
	cfg.Sync.Interval = defaultSyncInterval.String()
	cfg.Sync.UpdateLookback = defaultUpdateLookback.String()
	cfg.Notifications.Enabled = false
	cfg.Notifications.Provider = defaultNotificationProv
	cfg.Notifications.Preview = defaultNotificationPrev
	cfg.Webhook.URL = ""
	cfg.FCM.Enabled = false
	cfg.FCM.ProjectID = ""
	cfg.FCM.ServiceAccountPath = ""
	cfg.HMS.Enabled = false
	cfg.HMS.AppID = ""
	cfg.HMS.AppSecret = ""
	cfg.HMS.TokenCachePath = "~/.micago/hms-token.json"
	cfg.Firebase.PublicURLSync = false
	cfg.Firebase.URLCollection = "server"
	cfg.Firebase.URLDocument = "config"
	return cfg
}

func renderConfig(cfg fileConfig) string {
	return strings.Join([]string{
		"server:",
		fmt.Sprintf("  addr: %s", quoteYAML(cfg.Server.Addr)),
		fmt.Sprintf("  public_url: %s", quoteYAML(cfg.Server.PublicURL)),
		"",
		"network:",
		fmt.Sprintf("  public_base_url: %s", quoteYAML(cfg.Network.PublicBaseURL)),
		fmt.Sprintf("  verify_tls: %t", cfg.Network.VerifyTLS),
		fmt.Sprintf("  preferred_pairing_endpoint: %s", quoteYAML(cfg.Network.PreferredPairingEndpoint)),
		"",
		"auth:",
		fmt.Sprintf("  token: %s", quoteYAML(cfg.Auth.Token)),
		"",
		"sync:",
		fmt.Sprintf("  interval: %s", quoteYAML(cfg.Sync.Interval)),
		fmt.Sprintf("  update_lookback: %s", quoteYAML(cfg.Sync.UpdateLookback)),
		"",
		"notifications:",
		fmt.Sprintf("  enabled: %t", cfg.Notifications.Enabled),
		fmt.Sprintf("  provider: %s", quoteYAML(cfg.Notifications.Provider)),
		fmt.Sprintf("  preview: %s", quoteYAML(cfg.Notifications.Preview)),
		"",
		"webhook:",
		fmt.Sprintf("  url: %s", quoteYAML(cfg.Webhook.URL)),
		"",
		"fcm:",
		fmt.Sprintf("  enabled: %t", cfg.FCM.Enabled),
		fmt.Sprintf("  project_id: %s", quoteYAML(cfg.FCM.ProjectID)),
		fmt.Sprintf("  service_account_path: %s", quoteYAML(cfg.FCM.ServiceAccountPath)),
		fmt.Sprintf("  google_services_path: %s", quoteYAML(cfg.FCM.GoogleServicesPath)),
		"",
		"hms:",
		fmt.Sprintf("  enabled: %t", cfg.HMS.Enabled),
		fmt.Sprintf("  app_id: %s", quoteYAML(cfg.HMS.AppID)),
		fmt.Sprintf("  app_secret: %s", quoteYAML(cfg.HMS.AppSecret)),
		fmt.Sprintf("  token_cache_path: %s", quoteYAML(cfg.HMS.TokenCachePath)),
		"",
		"firebase:",
		fmt.Sprintf("  public_url_sync: %t", cfg.Firebase.PublicURLSync),
		fmt.Sprintf("  url_collection: %s", quoteYAML(cfg.Firebase.URLCollection)),
		fmt.Sprintf("  url_document: %s", quoteYAML(cfg.Firebase.URLDocument)),
		"",
	}, "\n")
}

func parseConfig(body string) (fileConfig, error) {
	cfg := defaultFileConfig("")
	section := ""
	lines := strings.Split(body, "\n")
	for _, rawLine := range lines {
		line := strings.TrimRight(rawLine, " \t\r")
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if !strings.HasPrefix(line, " ") && strings.HasSuffix(trimmed, ":") {
			section = strings.TrimSuffix(trimmed, ":")
			continue
		}
		if !strings.HasPrefix(line, "  ") {
			continue
		}
		key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		value = strings.Trim(value, `"`)
		switch section {
		case "server":
			switch key {
			case "addr":
				cfg.Server.Addr = value
			case "public_url":
				cfg.Server.PublicURL = value
			}
		case "network":
			switch key {
			case "public_base_url":
				cfg.Network.PublicBaseURL = value
			case "verify_tls":
				cfg.Network.VerifyTLS = parseBool(value)
			case "preferred_pairing_endpoint":
				cfg.Network.PreferredPairingEndpoint = value
			}
		case "auth":
			if key == "token" {
				cfg.Auth.Token = value
			}
		case "sync":
			switch key {
			case "interval":
				cfg.Sync.Interval = value
			case "update_lookback":
				cfg.Sync.UpdateLookback = value
			}
		case "notifications":
			switch key {
			case "enabled":
				cfg.Notifications.Enabled = parseBool(value)
			case "provider":
				cfg.Notifications.Provider = value
			case "preview":
				cfg.Notifications.Preview = value
			}
		case "webhook":
			if key == "url" {
				cfg.Webhook.URL = value
			}
		case "fcm":
			switch key {
			case "enabled":
				cfg.FCM.Enabled = parseBool(value)
			case "project_id":
				cfg.FCM.ProjectID = value
			case "service_account_path":
				cfg.FCM.ServiceAccountPath = value
			case "google_services_path":
				cfg.FCM.GoogleServicesPath = value
			}
		case "hms":
			switch key {
			case "enabled":
				cfg.HMS.Enabled = parseBool(value)
			case "app_id":
				cfg.HMS.AppID = value
			case "app_secret":
				cfg.HMS.AppSecret = value
			case "token_cache_path":
				cfg.HMS.TokenCachePath = value
			}
		case "firebase":
			switch key {
			case "public_url_sync":
				cfg.Firebase.PublicURLSync = parseBool(value)
			case "url_collection":
				cfg.Firebase.URLCollection = value
			case "url_document":
				cfg.Firebase.URLDocument = value
			}
		}
	}
	if cfg.Server.Addr == "" {
		cfg.Server.Addr = defaultAddr
	}
	if cfg.Sync.Interval == "" {
		cfg.Sync.Interval = defaultSyncInterval.String()
	}
	if cfg.Notifications.Provider == "" {
		cfg.Notifications.Provider = defaultNotificationProv
	}
	if cfg.Notifications.Preview == "" {
		cfg.Notifications.Preview = defaultNotificationPrev
	}
	if cfg.HMS.TokenCachePath == "" {
		cfg.HMS.TokenCachePath = "~/.micago/hms-token.json"
	}
	if cfg.Network.PreferredPairingEndpoint == "" {
		cfg.Network.PreferredPairingEndpoint = defaultPreferredPairing
	}
	return cfg, nil
}

func generateToken() (string, error) {
	buf := make([]byte, tokenBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

func quoteYAML(v string) string {
	return strconv.Quote(v)
}

func parseBool(v string) bool {
	b, _ := strconv.ParseBool(strings.ToLower(strings.TrimSpace(v)))
	return b
}

func valueOrDefault(primary, secondary, fallback string) string {
	if strings.TrimSpace(primary) != "" {
		return strings.TrimSpace(primary)
	}
	if strings.TrimSpace(secondary) != "" {
		return strings.TrimSpace(secondary)
	}
	return fallback
}

func expandPath(home, value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if strings.HasPrefix(value, "~/") {
		return filepath.Join(home, strings.TrimPrefix(value, "~/"))
	}
	return value
}

func addrHost(addr string) string {
	host, _, err := net.SplitHostPort(addr)
	if err == nil {
		return strings.Trim(host, "[]")
	}
	if strings.Contains(err.Error(), "missing port in address") {
		return strings.Trim(addr, "[]")
	}
	return strings.Trim(addr, "[]")
}
