package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func releaseFixture() clientReleaseConfig {
	return clientReleaseConfig{Revision: 7, Stable: clientChannelPolicy{Enabled: true, Minimum: 174, Latest: 180, DownloadURL: "https://am.meowcr.cn/download", Message: "修复说明"}, Beta: clientChannelPolicy{Latest: 174}}
}
func TestClientReleaseChannelAndDeadline(t *testing.T) {
	c := releaseFixture()
	cases := []struct {
		channel         string
		code            int
		blocked, update bool
	}{
		{"stable", 173, true, true}, {"stable", 174, false, true}, {"stable", 180, false, false}, {"stable", 999, false, false},
		{"beta", 173, false, false}, {"", 0, false, true}, {"bogus", 1000, false, false},
	}
	for _, v := range cases {
		d := decideClientRelease(c, v.channel, v.code, 1000)
		if d.Blocked != v.blocked || d.UpdateAvailable != v.update {
			t.Fatalf("%+v: %+v", v, d)
		}
	}
	c.Stable.ForceAfter = 2000
	if decideClientRelease(c, "stable", 173, 1999).Blocked || !decideClientRelease(c, "stable", 173, 2000).Blocked {
		t.Fatal("deadline boundary")
	}
	c.RejectLegacy = true
	if decideClientRelease(c, "", 0, 1999).Blocked || !decideClientRelease(c, "", 0, 2000).Blocked {
		t.Fatal("legacy must follow explicit switch and stable deadline")
	}
	c.Beta = clientChannelPolicy{Enabled: true, Retired: true, DownloadURL: c.Stable.DownloadURL}
	if !decideClientRelease(c, "beta", 999999, 2000).Blocked || decideClientRelease(c, "stable", 999999, 2000).Blocked {
		t.Fatal("beta retirement leaked across channels")
	}
}
func TestClientReleaseValidation(t *testing.T) {
	if validateClientReleaseConfig(clientReleaseConfig{}) != nil {
		t.Fatal("default must be disabled")
	}
	for _, change := range []func(*clientReleaseConfig){
		func(c *clientReleaseConfig) { c.Stable.Minimum = 181 }, func(c *clientReleaseConfig) { c.Stable.DownloadURL = "http://example.test" },
		func(c *clientReleaseConfig) { c.Stable.DownloadURL = "https://user:secret@example.test/a" }, func(c *clientReleaseConfig) { c.Stable.Retired = true },
		func(c *clientReleaseConfig) { c.Stable.ForceAfter = -1 }, func(c *clientReleaseConfig) { c.Stable.Message = strings.Repeat("字", 501) },
		func(c *clientReleaseConfig) { c.RejectLegacy = true; c.Stable.Enabled = false },
	} {
		c := releaseFixture()
		change(&c)
		if validateClientReleaseConfig(c) == nil {
			t.Fatalf("accepted invalid configuration: %+v", c)
		}
	}
}
func TestClientReleaseHTTPGateAndRecoveryPaths(t *testing.T) {
	c := releaseFixture()
	clientReleasePolicies.Lock()
	clientReleasePolicies.db = nil
	clientReleasePolicies.at = time.Now()
	clientReleasePolicies.value = c
	clientReleasePolicies.Unlock()
	defer func() {
		clientReleasePolicies.Lock()
		clientReleasePolicies.at = time.Time{}
		clientReleasePolicies.Unlock()
	}()
	s := &server{}
	for _, path := range []string{"/ios/authorize", "/ios/access", "/ios/session/activate", "/ios/plugins/manifest", "/cloud/projects"} {
		r := httptest.NewRequest("GET", "/api"+path, nil)
		r.Header.Set("X-AM-Platform", "ios")
		r.Header.Set("X-AM-Release-Code", "173")
		r.Header.Set("X-AM-Release-Channel", "stable")
		w := httptest.NewRecorder()
		if !s.clientReleaseBlocked(w, r, path) || w.Code != 426 {
			t.Fatal(path, w.Code)
		}
		var body struct {
			Data struct {
				Policy clientReleaseDecision `json:"clientReleasePolicy"`
			} `json:"data"`
		}
		if json.Unmarshal(w.Body.Bytes(), &body) != nil || body.Data.Policy.Channel != "stable" || !body.Data.Policy.Blocked {
			t.Fatal(w.Body.String())
		}
		r.Header.Set("X-AM-Release-Channel", "beta")
		if s.clientReleaseBlocked(httptest.NewRecorder(), r, path) {
			t.Fatal("disabled beta blocked", path)
		}
		r.Header.Set("X-AM-Platform", "web")
		if s.clientReleaseBlocked(httptest.NewRecorder(), r, path) {
			t.Fatal("web blocked", path)
		}
	}
	for _, path := range []string{"/ios/client-release", "/health", "/support/tickets", "/support/tickets/1/attachments", "/auth/login", "/auth/logout", "/user/me"} {
		if clientReleaseProtectedPath(path) {
			t.Fatal("recovery path blocked", path)
		}
	}
	r := httptest.NewRequest("GET", "/api/ios/client-release", nil)
	r.Header.Set("X-AM-Release-Code", "173")
	r.Header.Set("X-AM-Release-Channel", "stable")
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, r)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"minimumRelease":174`) {
		t.Fatal(w.Code, w.Body.String())
	}
}
func TestClientReleaseFormPreviewAndEscaping(t *testing.T) {
	values := url.Values{"stable_enabled": {"1"}, "stable_latest": {"180"}, "stable_minimum": {"174"}, "stable_url": {"https://am.meowcr.cn/download"}, "stable_date": {"2026-11-27T18:30"}, "stable_message": {"<script>alert(1)</script>"}}
	r := httptest.NewRequest("POST", "/admin/client-releases", strings.NewReader(values.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	c, err := parseClientReleaseForm(r)
	if err != nil {
		t.Fatal(err)
	}
	if time.Unix(c.Stable.ForceAfter, 0).In(releaseBeijing).Format("2006-01-02 15:04") != "2026-11-27 18:30" {
		t.Fatal("timezone mismatch")
	}
	var html bytes.Buffer
	if err = clientReleaseTemplate.Execute(&html, &pageData{Data: clientReleasePageData(c, 1000)}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(html.String(), "<script>alert(1)</script>") || !strings.Contains(html.String(), "&lt;script&gt;") || !strings.Contains(html.String(), `name="_csrf"`) {
		t.Fatal("escaping/csrf fields missing")
	}
	values.Set("stable_minimum", "invalid")
	r = httptest.NewRequest("POST", "/", strings.NewReader(values.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if _, err = parseClientReleaseForm(r); err == nil {
		t.Fatal("invalid numeric form accepted")
	}
}
func TestClientReleaseRetirementPreviewAndTicketIdentity(t *testing.T) {
	c := clientReleaseConfig{Beta: clientChannelPolicy{Enabled: true, Retired: true, DownloadURL: "https://example.test/release"}}
	found := false
	for _, row := range clientReleasePageData(c, 1000).Preview {
		if row.Channel == "Beta 测试版" && row.Result == "结束测试，迁移正式版" {
			found = true
		}
	}
	if !found {
		t.Fatal("retired Beta with zero minimum/latest has no preview")
	}
	r := httptest.NewRequest("POST", "/support/tickets", nil)
	if clientReleaseTicketContent("text", r) != "text" {
		t.Fatal("web content changed")
	}
	r.Header.Set("X-AM-Platform", "ios")
	if !strings.Contains(clientReleaseTicketContent("text", r), "版本未上报") {
		t.Fatal("legacy annotation missing")
	}
	r.Header.Set("X-AM-Release-Code", "174")
	r.Header.Set("X-AM-Release-Channel", "beta")
	r.Header.Set("X-AM-Release-Build", "123456789abc")
	if !strings.Contains(clientReleaseTicketContent("text", r), "r174 · beta · 123456789abc") {
		t.Fatal("identity missing")
	}
	r.Header.Set("X-AM-Release-Build", "<script>bad</script>")
	if strings.Contains(clientReleaseTicketContent("text", r), "<script>") {
		t.Fatal("untrusted build accepted")
	}
}
func TestClientReleaseSaveTemporaryTable(t *testing.T) {
	path := os.Getenv("AM_RELEASE_TEST_CONFIG")
	if path == "" {
		t.Skip("opt-in real SQL test uses connection-local temporary table only")
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal("cannot load test configuration")
	}
	db, err := sql.Open("mysql", cfg.DSN)
	if err != nil {
		t.Fatal("cannot open test connection")
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	// MySQL resolves this connection-local temporary table before the live table.
	_, err = db.Exec(`CREATE TEMPORARY TABLE system_config(cfg_key VARCHAR(100) PRIMARY KEY,cfg_value TEXT,updated_by BIGINT)`)
	if err != nil {
		t.Fatal("cannot create isolated temporary table")
	}
	defer db.Exec(`DROP TEMPORARY TABLE system_config`)
	c, err := readClientReleaseConfig(db)
	if err != nil || c.Revision != 0 || c.Stable.Enabled || c.Beta.Enabled {
		t.Fatal("default is not disabled")
	}
	var success atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if saveClientReleaseConfig(db, 1, releaseFixture(), 0) == nil {
				success.Add(1)
			}
		}()
	}
	wg.Wait()
	if success.Load() != 1 {
		t.Fatalf("concurrent initial saves accepted %d", success.Load())
	}
	c, err = loadClientReleaseConfig(db)
	if err != nil || c.Revision != 1 || !c.Stable.Enabled {
		t.Fatal("saved policy unavailable")
	}
	c.Stable.Enabled = false
	c.Beta.Enabled = false
	c.RejectLegacy = false
	if err = saveClientReleaseConfig(db, 1, c, 1); err != nil {
		t.Fatal("revoke failed")
	}
	c, err = loadClientReleaseConfig(db)
	if err != nil || c.Revision != 2 || decideClientRelease(c, "stable", 1, 1000).Blocked {
		t.Fatal("revoked policy still blocked")
	}
}
