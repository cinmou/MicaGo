package app

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"micagoserver/internal/config"
	"micagoserver/internal/httpapi"
	"micagoserver/internal/notify"
	"micagoserver/internal/realtime"
	"micagoserver/internal/relaydb"
	micasend "micagoserver/internal/send"
	"micagoserver/internal/store"
)

type Options struct {
	SyncOnce        bool
	APIStore        string
	SyncInterval    string
	DisableSyncLoop bool
	Addr            string
	Token           string
	DisableAuth     bool
	PublicURL       string
}

type apiQueryService interface {
	ListRecentMessages(ctx context.Context, limit, offset int, service string, includeEmpty bool) ([]store.MessageJSON, error)
	ListChats(ctx context.Context, limit, offset int, withArchived bool, service string) ([]store.ChatJSON, error)
	ChatExists(ctx context.Context, guid string) (bool, error)
	GetChatInfo(ctx context.Context, guid string) (*store.ChatInfo, error)
	ListChatMessages(ctx context.Context, guid string, limit, offset int, includeEmpty bool) ([]store.MessageJSON, error)
	FindOutgoingMessageMatch(ctx context.Context, guid string, normalizedText string, sentAtUnixMilli int64) (*store.MessageJSON, error)
}

func Run(options Options) error {
	cfg, err := config.Load(config.Options{
		Addr:            options.Addr,
		Token:           options.Token,
		DisableAuth:     options.DisableAuth,
		PublicURL:       options.PublicURL,
		SyncInterval:    options.SyncInterval,
		DisableSyncLoop: options.DisableSyncLoop,
		SyncOnce:        options.SyncOnce,
		APIStore:        options.APIStore,
	})
	if err != nil {
		return err
	}
	if err := config.ValidateSecurity(cfg); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if cfg.FirstRun {
		log.Printf("created config file: %s", cfg.ConfigPath)
		log.Printf("first-run auth token: %s", cfg.AuthToken)
	}
	if !config.IsLocalAddress(cfg.HTTPAddr) {
		log.Printf("warning: binding to non-local address %s; ensure your network exposure and auth settings are intentional", cfg.HTTPAddr)
	}
	if config.IsWildcardAddress(cfg.HTTPAddr) {
		log.Printf("warning: %s listens on all interfaces", cfg.HTTPAddr)
	}

	db, err := store.OpenReadOnly(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("open chat.db: %w", err)
	}
	defer db.Close()

	queries := store.NewQueries(db)
	relay, err := relaydb.Open(cfg.RelayDBPath)
	if err != nil {
		return fmt.Errorf("open relay.db: %w", err)
	}
	defer relay.Close()

	log.Printf("relay.db path: %s", cfg.RelayDBPath)
	hub := realtime.NewHub()
	defer hub.Close()
	dispatcher := notify.NewDispatcher(cfg)
	var syncMu sync.Mutex
	runSync := func(ctx context.Context) (relaydb.SyncResult, error) {
		syncMu.Lock()
		defer syncMu.Unlock()
		return relaydb.SyncOnce(ctx, queries, relay, cfg.InitialSyncLimit)
	}

	if cfg.SyncOnce {
		result, err := runSync(ctx)
		if err != nil {
			return err
		}

		logSyncResult(result, true)
		return nil
	}

	startupSync, err := runSync(ctx)
	if err != nil {
		return err
	}
	logSyncResult(startupSync, true)
	broadcastSyncResult(ctx, hub, startupSync)
	dispatchNotifications(ctx, dispatcher, relay, startupSync)

	if !cfg.DisableSyncLoop {
		interval := cfg.SyncInterval
		if interval <= 0 {
			interval = 5 * time.Second
		}
		go runSyncLoop(ctx, interval, runSync, hub, dispatcher, relay)
	}

	apiStore := options.APIStore
	if apiStore == "" {
		apiStore = cfg.DefaultAPIStore
	}

	apiQueries, err := selectAPIStore(apiStore, queries, relay)
	if err != nil {
		return err
	}

	sendDeps := &httpapi.SendDependencies{
		Pending: micasend.NewPendingSendManager(),
		Sender:  micasend.AppleScriptSender{},
		SyncNow: func(ctx context.Context) error {
			result, err := runSync(ctx)
			if err == nil {
				broadcastSyncResult(ctx, hub, result)
				dispatchNotifications(ctx, dispatcher, relay, result)
			}
			return err
		},
		Events: hub,
	}

	capabilities, err := store.ProbeCapabilities(ctx, db)
	if err != nil {
		log.Printf("chat.db schema probe failed (capabilities default to false): %v", err)
	} else {
		log.Printf("chat.db capabilities: %+v", capabilities)
	}

	statusDeps := httpapi.StatusDeps{
		APIStore:     apiStore,
		ClientCount:  hub.ClientCount,
		SyncState:    relay.GetSyncState,
		Network:      httpapi.NewNetworkController(cfg),
		Capabilities: capabilities,
	}

	handler := httpapi.NewRouter(
		httpapi.NewHandlers(apiQueries, log.Default(), sendDeps, relay, cfg.AttachmentsRoot, relay, dispatcher, cfg, statusDeps),
		hub,
		httpapi.AuthConfig{Enabled: !cfg.AuthDisabled, Token: cfg.AuthToken},
	)

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	log.Printf("api-store: %s", apiStore)
	log.Printf("listening on http://%s", cfg.HTTPAddr)

	err = srv.ListenAndServe()
	if err != nil && err != http.ErrServerClosed {
		if errors.Is(err, syscall.EADDRINUSE) {
			log.Printf("failed to bind %s: address already in use; check which process is listening with: lsof -nP -iTCP:3000 -sTCP:LISTEN", cfg.HTTPAddr)
		}
		return err
	}

	return nil
}

func runSyncLoop(
	ctx context.Context,
	interval time.Duration,
	syncNow func(context.Context) (relaydb.SyncResult, error),
	hub *realtime.Hub,
	dispatcher *notify.Dispatcher,
	relay *relaydb.DB,
) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			result, err := syncNow(ctx)
			if err != nil {
				log.Printf("periodic sync failed: %v", err)
				if hub != nil {
					_ = hub.Broadcast(ctx, realtime.Event{
						Type: "sync:error",
						Data: map[string]any{
							"message": "periodic sync failed",
						},
					})
				}
				continue
			}
			logSyncResult(result, false)
			broadcastSyncResult(ctx, hub, result)
			dispatchNotifications(ctx, dispatcher, relay, result)
		}
	}
}

func broadcastSyncResult(ctx context.Context, hub *realtime.Hub, result relaydb.SyncResult) {
	if hub == nil {
		return
	}
	for _, message := range result.NewMessages {
		_ = hub.Broadcast(ctx, realtime.Event{
			Type: "message:new",
			Data: message,
		})
	}
}

func logSyncResult(result relaydb.SyncResult, force bool) {
	if !force && result.MessagesSynced == 0 {
		return
	}

	log.Printf("sync mode: %s", result.Mode)
	log.Printf("previous last_message_rowid: %d", result.PreviousLastMessageRowID)
	log.Printf("synced chats: %d", result.ChatsSynced)
	log.Printf("synced messages: %d", result.MessagesSynced)
	log.Printf("new last_message_rowid: %d", result.NewLastMessageRowID)
	if result.LastMessageGUID != "" {
		log.Printf("last synced message: guid=%s dateCreated=%d", result.LastMessageGUID, result.LastMessageDateCreated)
	}
}

func dispatchNotifications(ctx context.Context, dispatcher *notify.Dispatcher, relay *relaydb.DB, result relaydb.SyncResult) {
	if dispatcher == nil || len(result.NotificationEvents) == 0 || relay == nil {
		return
	}
	devices, err := relay.ListDevices(ctx)
	if err != nil {
		log.Printf("list devices for notification dispatch: %v", err)
		return
	}
	if err := dispatcher.DispatchNewMessages(ctx, devices, result.NotificationEvents); err != nil {
		log.Printf("dispatch notifications: %v", err)
	}
}

func selectAPIStore(name string, chatdb *store.Queries, relay *relaydb.DB) (apiQueryService, error) {
	switch name {
	case "relaydb":
		return relay, nil
	case "chatdb":
		return chatdb, nil
	default:
		return nil, fmt.Errorf("invalid api-store %q: expected relaydb or chatdb", name)
	}
}
