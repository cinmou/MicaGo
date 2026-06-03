package main

import (
	"flag"
	"log"

	"micagoserver/internal/app"
)

func main() {
	syncOnce := flag.Bool("sync-once", false, "run one relay.db sync and exit")
	apiStore := flag.String("api-store", "", "API backing store: relaydb or chatdb")
	syncInterval := flag.String("sync-interval", "", "periodic relay sync interval")
	disableSyncLoop := flag.Bool("disable-sync-loop", false, "disable periodic relay sync loop")
	addr := flag.String("addr", "", "HTTP listen address")
	token := flag.String("token", "", "Bearer token for API and WebSocket auth")
	disableAuth := flag.Bool("disable-auth", false, "disable auth for localhost-only development")
	publicURL := flag.String("public-url", "", "public base URL used for server info")
	flag.Parse()

	if err := app.Run(app.Options{
		SyncOnce:        *syncOnce,
		APIStore:        *apiStore,
		SyncInterval:    *syncInterval,
		DisableSyncLoop: *disableSyncLoop,
		Addr:            *addr,
		Token:           *token,
		DisableAuth:     *disableAuth,
		PublicURL:       *publicURL,
	}); err != nil {
		log.Fatal(err)
	}
}
