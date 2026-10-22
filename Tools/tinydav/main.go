// Command tinydav is the runner-native WebDAV fixture for MobileOrg's
// WebDavTests. It replaces the Docker-based phylor/webdav-ssl image used by
// the old test setup, which GitHub macOS runners cannot host: it serves a
// fixture directory over HTTPS with HTTP basic auth, so any machine with a
// Go toolchain can host the tests.
//
// The fixture TLS certificate in MobileOrgTests/Resources/WebDavTests/certs
// is self-signed (and long expired); the app's URLSession challenge handler
// accepts any server certificate, as it did against the Docker server.
//
// Build with the vendored dependencies (no network access required):
//
//	go build -mod=vendor -o tinydav .
package main

import (
	"crypto/subtle"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"

	"golang.org/x/net/webdav"
)

func main() {
	root := flag.String("root", "", "directory to serve over WebDAV (required)")
	port := flag.Int("port", 32773, "TCP port to listen on")
	user := flag.String("user", "", "basic-auth username (required)")
	password := flag.String("password", "", "basic-auth password (required)")
	certFile := flag.String("tls-cert", "", "path to the TLS certificate (required)")
	keyFile := flag.String("tls-key", "", "path to the TLS private key (required)")
	flag.Parse()

	if *root == "" || *user == "" || *password == "" || *certFile == "" || *keyFile == "" {
		fmt.Fprintln(os.Stderr, "tinydav: -root, -user, -password, -tls-cert and -tls-key are all required")
		flag.Usage()
		os.Exit(2)
	}

	dav := &webdav.Handler{
		FileSystem: webdav.Dir(*root),
		LockSystem: webdav.NewMemLS(),
		Logger: func(r *http.Request, err error) {
			log.Printf("webdav: %s %s: %v", r.Method, r.URL.Path, err)
		},
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !basicAuthOK(r, *user, *password) {
			w.Header().Set("WWW-Authenticate", `Basic realm="tinydav"`)
			http.Error(w, "401 Unauthorized", http.StatusUnauthorized)
			return
		}
		dav.ServeHTTP(w, r)
	})

	// Loopback only: the fixture credentials are public test values committed
	// to this repository, and the iOS simulator shares the host network stack,
	// so there is no reason to expose a weakly-authenticated server on the LAN.
	addr := net.JoinHostPort("127.0.0.1", fmt.Sprint(*port))
	log.Printf("tinydav: serving %s at https://%s (basic auth enabled)", *root, addr)
	log.Fatal(http.ListenAndServeTLS(addr, *certFile, *keyFile, handler))
}

// basicAuthOK checks request credentials in constant time. The fixture
// credentials are public test values committed to this repository; the server
// exists so WebDavTests exercise the real 401-then-authorize exchange.
func basicAuthOK(r *http.Request, user, password string) bool {
	reqUser, reqPass, ok := r.BasicAuth()
	if !ok {
		return false
	}
	userOK := subtle.ConstantTimeCompare([]byte(reqUser), []byte(user)) == 1
	passOK := subtle.ConstantTimeCompare([]byte(reqPass), []byte(password)) == 1
	return userOK && passOK
}
