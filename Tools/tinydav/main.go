// Command tinydav is the runner-native WebDAV fixture for MobileOrg's
// WebDavTests. It replaces the Docker-based phylor/webdav-ssl image used by
// the old test setup, which GitHub macOS runners cannot host: it serves a
// fixture directory over HTTPS with HTTP basic auth, so any machine with a
// Go toolchain can host the tests.
//
// The fixture serves a fresh throwaway TLS certificate per launch (see
// Scripts/WebDAV-Server-Start.sh); the app's URLSession challenge handler
// accepts any server certificate, as it did against the Docker server.
//
// Test isolation and request evidence (regression harness): when started with
// -pristine, the server also opens a plain-HTTP control port (loopback only)
// exposing three authenticated endpoints used by the test suite:
//
//	POST /reset?profile=NAME  restore the working root from
//	                          <pristine>/NAME, clear the request log, and
//	                          answer {"ok":true,"since":N} where N is the
//	                          log cutoff the test should query from.
//	GET  /log?since=N         {"requests":[{seq,method,path},...]} for every
//	                          logged request with seq > N.
//	GET  /golden?profile=NAME the profile's committed golden-manifest.json
//	                          (served from the pristine copy, never from the
//	                          working root the app mutates).
//
// Build with the vendored dependencies (no network access required):
//
//	go build -mod=vendor -o tinydav .
package main

import (
	"crypto/subtle"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"

	"golang.org/x/net/webdav"
)

// requestLogEntry is one fixture request as observed by the control plane.
type requestLogEntry struct {
	Seq    int    `json:"seq"`
	Method string `json:"method"`
	Path   string `json:"path"`
}

// fixtureState carries the per-test reset/log machinery shared between the
// WebDAV handler and the control port.
type fixtureState struct {
	mu          sync.Mutex
	pristineDir string
	root        string
	seq         int
	log         []requestLogEntry
}

func (s *fixtureState) record(r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.seq++
	s.log = append(s.log, requestLogEntry{Seq: s.seq, Method: r.Method, Path: r.URL.Path})
}

func (s *fixtureState) entriesSince(since int) []requestLogEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []requestLogEntry{}
	for _, e := range s.log {
		if e.Seq > since {
			out = append(out, e)
		}
	}
	return out
}

func (s *fixtureState) cutoff() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.seq
}

// reset restores the working root from <pristine>/<profile> and clears the
// request log. The sequence counter stays monotonic so log windows remain
// unambiguous across resets.
func (s *fixtureState) reset(profile string) error {
	src := filepath.Join(s.pristineDir, profile)
	info, err := os.Stat(src)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("no such fixture profile %q", profile)
	}
	entries, err := os.ReadDir(s.root)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if err := os.RemoveAll(filepath.Join(s.root, e.Name())); err != nil {
			return err
		}
	}
	if err := copyTree(src, s.root); err != nil {
		return err
	}
	s.mu.Lock()
	s.log = nil
	s.mu.Unlock()
	return nil
}

// copyTree copies the src directory tree into dst (dst created if needed).
func copyTree(src, dst string) error {
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		in, err := os.Open(path)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			return err
		}
		defer out.Close()
		_, err = io.Copy(out, in)
		return err
	})
}

func main() {
	root := flag.String("root", "", "directory to serve over WebDAV (required)")
	port := flag.Int("port", 32773, "TCP port to listen on")
	user := flag.String("user", "", "basic-auth username (required)")
	password := flag.String("password", "", "basic-auth password (required)")
	certFile := flag.String("tls-cert", "", "path to the TLS certificate (required)")
	keyFile := flag.String("tls-key", "", "path to the TLS private key (required)")
	pristineDir := flag.String("pristine", "", "directory of pristine fixture profiles (enables the control port)")
	initialProfile := flag.String("initial-profile", "", "profile to copy into -root at startup (requires -pristine)")
	controlPort := flag.Int("control-port", 32774, "TCP port for the plain-HTTP control plane (loopback only)")
	flag.Parse()

	if *root == "" || *user == "" || *password == "" || *certFile == "" || *keyFile == "" {
		fmt.Fprintln(os.Stderr, "tinydav: -root, -user, -password, -tls-cert and -tls-key are all required")
		flag.Usage()
		os.Exit(2)
	}

	state := &fixtureState{pristineDir: *pristineDir, root: *root}
	if *initialProfile != "" {
		if *pristineDir == "" {
			fmt.Fprintln(os.Stderr, "tinydav: -initial-profile requires -pristine")
			os.Exit(2)
		}
		if err := state.reset(*initialProfile); err != nil {
			log.Fatalf("tinydav: initial fixture populate failed: %v", err)
		}
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
			log.Printf("tinydav: %s %s from %s: 401 (missing or bad credentials)", r.Method, r.URL.Path, r.RemoteAddr)
			w.Header().Set("WWW-Authenticate", `Basic realm="tinydav"`)
			http.Error(w, "401 Unauthorized", http.StatusUnauthorized)
			return
		}
		log.Printf("tinydav: %s %s from %s: authorized", r.Method, r.URL.Path, r.RemoteAddr)
		state.record(r)
		dav.ServeHTTP(w, r)
	})

	// Loopback only: the fixture credentials are public test values committed
	// to this repository, and the iOS simulator shares the host network stack,
	// so there is no reason to expose a weakly-authenticated server on the LAN.
	addr := net.JoinHostPort("127.0.0.1", fmt.Sprint(*port))
	log.Printf("tinydav: serving %s at https://%s (basic auth enabled)", *root, addr)
	go func() {
		log.Fatal(http.ListenAndServeTLS(addr, *certFile, *keyFile, handler))
	}()

	if *pristineDir != "" {
		controlMux := http.NewServeMux()
		controlMux.HandleFunc("/reset", func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodPost {
				http.Error(w, "POST only", http.StatusMethodNotAllowed)
				return
			}
			if !basicAuthOK(r, *user, *password) {
				http.Error(w, "401 Unauthorized", http.StatusUnauthorized)
				return
			}
			profile := r.URL.Query().Get("profile")
			if err := state.reset(profile); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]interface{}{"ok": true, "profile": profile, "since": state.cutoff()})
		})
		controlMux.HandleFunc("/log", func(w http.ResponseWriter, r *http.Request) {
			if !basicAuthOK(r, *user, *password) {
				http.Error(w, "401 Unauthorized", http.StatusUnauthorized)
				return
			}
			var since int
			fmt.Sscanf(r.URL.Query().Get("since"), "%d", &since)
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]interface{}{"requests": state.entriesSince(since)})
		})
		controlMux.HandleFunc("/golden", func(w http.ResponseWriter, r *http.Request) {
			if !basicAuthOK(r, *user, *password) {
				http.Error(w, "401 Unauthorized", http.StatusUnauthorized)
				return
			}
			profile := r.URL.Query().Get("profile")
			manifest, err := os.ReadFile(filepath.Join(*pristineDir, profile, "golden-manifest.json"))
			if err != nil {
				http.Error(w, fmt.Sprintf("no manifest for profile %q", profile), http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.Write(manifest)
		})

		controlAddr := net.JoinHostPort("127.0.0.1", fmt.Sprint(*controlPort))
		log.Printf("tinydav: control plane at http://%s (reset/log/golden)", controlAddr)
		log.Fatal(http.ListenAndServe(controlAddr, controlMux))
	} else {
		log.Printf("tinydav: no -pristine given; control plane disabled (reset/log endpoints unavailable)")
		select {}
	}
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
