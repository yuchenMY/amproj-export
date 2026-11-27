package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const clientReleaseConfigKey = "ios_client_release_policy_v1"

type clientChannelPolicy struct {
	Enabled     bool   `json:"enabled"`
	Minimum     int    `json:"minimumRelease"`
	Latest      int    `json:"latestRelease"`
	ForceAfter  int64  `json:"forceAfter"`
	DownloadURL string `json:"downloadURL"`
	Message     string `json:"message"`
	Retired     bool   `json:"retired"`
}
type clientReleaseConfig struct {
	Revision     int64               `json:"revision"`
	Stable       clientChannelPolicy `json:"stable"`
	Beta         clientChannelPolicy `json:"beta"`
	RejectLegacy bool                `json:"rejectLegacy"`
}
type clientReleaseDecision struct {
	Protocol      int    `json:"protocol"`
	Channel       string `json:"channel"`
	ClientRelease int    `json:"clientRelease"`
	Revision      int64  `json:"revision"`
	ServerNow     int64  `json:"serverNow"`
	clientChannelPolicy
	Blocked         bool `json:"blocked"`
	UpdateAvailable bool `json:"updateAvailable"`
	Legacy          bool `json:"legacy"`
}

var clientReleasePolicies = struct {
	sync.Mutex
	db    *sql.DB
	at    time.Time
	value clientReleaseConfig
}{}

func validClientReleaseURL(value string) bool {
	u, err := url.Parse(value)
	return err == nil && u.Scheme == "https" && u.Hostname() != "" && u.User == nil
}
func validateClientReleaseConfig(c clientReleaseConfig) error {
	for name, p := range map[string]clientChannelPolicy{"stable": c.Stable, "beta": c.Beta} {
		if p.Minimum < 0 || p.Latest < 0 || p.Latest > 1000000000 || p.Minimum > p.Latest || p.ForceAfter < 0 {
			return errors.New("版本号须为非负整数，最低版本不能高于最新版本")
		}
		if name == "stable" && p.Retired {
			return errors.New("正式版不能使用结束 Beta 测试开关")
		}
		if len([]rune(p.Message)) > 500 {
			return errors.New("更新说明不能超过 500 字")
		}
		if p.DownloadURL != "" && !validClientReleaseURL(p.DownloadURL) {
			return errors.New("下载地址必须是有效的 HTTPS 地址")
		}
		if p.Enabled && (!validClientReleaseURL(p.DownloadURL) || (!p.Retired && p.Latest == 0)) {
			return errors.New("启用策略前请填写最新版本和 HTTPS 下载地址")
		}
	}
	if c.RejectLegacy && (!c.Stable.Enabled || c.Stable.Minimum == 0) {
		return errors.New("限制无版本旧包前，须启用正式版最低版本策略")
	}
	return nil
}
func decideClientRelease(c clientReleaseConfig, channel string, release int, now int64) clientReleaseDecision {
	p := c.Stable
	legacy := release <= 0 || (channel != "stable" && channel != "beta")
	if channel == "beta" && !legacy {
		p = c.Beta
	}
	if legacy {
		channel = "legacy"
	}
	d := clientReleaseDecision{Protocol: 1, Channel: channel, ClientRelease: release, Revision: c.Revision, ServerNow: now,
		clientChannelPolicy: p, Legacy: legacy}
	effective := p.ForceAfter == 0 || now >= p.ForceAfter
	d.Blocked = p.Enabled && effective && (p.Retired || release < p.Minimum)
	if legacy {
		d.Blocked = c.RejectLegacy && c.Stable.Enabled && effective && c.Stable.Minimum > 0
	}
	d.UpdateAvailable = p.Enabled && (p.Retired || release < p.Latest)
	return d
}
func readClientReleaseConfig(db *sql.DB) (clientReleaseConfig, error) {
	if db == nil {
		return clientReleaseConfig{}, nil
	}
	var raw string
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err := db.QueryRowContext(ctx, `SELECT cfg_value FROM system_config WHERE cfg_key=?`, clientReleaseConfigKey).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return clientReleaseConfig{}, nil
	}
	if err != nil {
		return clientReleaseConfig{}, err
	}
	var c clientReleaseConfig
	if err = json.Unmarshal([]byte(raw), &c); err != nil {
		return c, err
	}
	return c, validateClientReleaseConfig(c)
}
func loadClientReleaseConfig(db *sql.DB) (clientReleaseConfig, error) {
	clientReleasePolicies.Lock()
	defer clientReleasePolicies.Unlock()
	if clientReleasePolicies.db == db && !clientReleasePolicies.at.IsZero() && time.Since(clientReleasePolicies.at) < 5*time.Second {
		return clientReleasePolicies.value, nil
	}
	c, err := readClientReleaseConfig(db)
	if err == nil {
		clientReleasePolicies.db = db
		clientReleasePolicies.value = c
		clientReleasePolicies.at = time.Now()
	}
	return c, err
}
func saveClientReleaseConfig(db *sql.DB, adminID int64, c clientReleaseConfig, expected int64) error {
	if err := validateClientReleaseConfig(c); err != nil {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// 先以唯一键建立默认行，首次保存也由事务行锁串行化。
	if _, err = tx.Exec(`INSERT IGNORE INTO system_config(cfg_key,cfg_value,updated_by) VALUES(?,?,?)`, clientReleaseConfigKey, `{"revision":0}`, adminID); err != nil {
		return err
	}
	var raw string
	err = tx.QueryRow(`SELECT cfg_value FROM system_config WHERE cfg_key=? FOR UPDATE`, clientReleaseConfigKey).Scan(&raw)
	var old clientReleaseConfig
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if raw != "" {
		if err = json.Unmarshal([]byte(raw), &old); err != nil {
			return err
		}
	}
	if old.Revision != expected {
		return errors.New("策略已被其他页面修改，请刷新后重新检查")
	}
	c.Revision = old.Revision + 1
	data, err := json.Marshal(c)
	if err != nil {
		return err
	}
	_, err = tx.Exec(`INSERT INTO system_config(cfg_key,cfg_value,updated_by) VALUES(?,?,?) ON DUPLICATE KEY UPDATE cfg_value=VALUES(cfg_value),updated_by=VALUES(updated_by)`, clientReleaseConfigKey, string(data), adminID)
	if err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	clientReleasePolicies.Lock()
	clientReleasePolicies.at = time.Time{}
	clientReleasePolicies.Unlock()
	return nil
}
func clientReleaseIdentity(r *http.Request) (string, int) {
	channel := strings.TrimSpace(r.Header.Get("X-AM-Release-Channel"))
	code, err := strconv.Atoi(r.Header.Get("X-AM-Release-Code"))
	if err != nil || code <= 0 || code > 1000000000 {
		code = 0
	}
	return channel, code
}
func (s *server) publicClientRelease(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	c, err := loadClientReleaseConfig(s.db)
	if err != nil {
		writeJSON(w, 503, map[string]any{"code": 503, "message": "版本状态暂时无法读取，请稍后重试"})
		return
	}
	channel, code := clientReleaseIdentity(r)
	ok(w, decideClientRelease(c, channel, code, time.Now().Unix()))
}
func clientReleaseProtectedPath(path string) bool {
	return path == "/ios/authorize" || path == "/ios/access" || path == "/ios/session/activate" ||
		path == "/plugins" || strings.HasPrefix(path, "/plugins/") || strings.HasPrefix(path, "/ios/plugins/") || path == "/cloud" || strings.HasPrefix(path, "/cloud/")
}
func (s *server) clientReleaseBlocked(w http.ResponseWriter, r *http.Request, path string) bool {
	if !strings.EqualFold(strings.TrimSpace(r.Header.Get("X-AM-Platform")), "ios") || !clientReleaseProtectedPath(path) {
		return false
	}
	c, err := loadClientReleaseConfig(s.db)
	if err != nil {
		return false
	}
	channel, code := clientReleaseIdentity(r)
	d := decideClientRelease(c, channel, code, time.Now().Unix())
	if !d.Blocked {
		return false
	}
	message := "当前版本已停止支持，请先备份工程并更新应用"
	if d.Retired {
		message = "Beta 测试已结束，请导出工程，在正式版导入并检查后再删除 Beta"
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusUpgradeRequired, map[string]any{"code": 426, "message": message, "data": map[string]any{"clientReleasePolicy": d}})
	return true
}

var releaseBeijing = time.FixedZone("Asia/Shanghai", 8*60*60)

type clientReleaseForm struct {
	Name, Label, Date string
	clientChannelPolicy
}
type clientReleasePreview struct {
	Channel string
	Code    int
	Result  string
}
type clientReleasePage struct {
	CSRF         string
	CanEdit      bool
	Revision     int64
	RejectLegacy bool
	Channels     []clientReleaseForm
	Preview      []clientReleasePreview
	Error        string
}

func clientReleasePageData(c clientReleaseConfig, now int64) *clientReleasePage {
	d := &clientReleasePage{Revision: c.Revision, RejectLegacy: c.RejectLegacy}
	for _, v := range []struct {
		name, label string
		p           clientChannelPolicy
	}{{"stable", "正式版", c.Stable}, {"beta", "Beta 测试版", c.Beta}} {
		date := ""
		if v.p.ForceAfter > 0 {
			date = time.Unix(v.p.ForceAfter, 0).In(releaseBeijing).Format("2006-01-02T15:04")
		}
		d.Channels = append(d.Channels, clientReleaseForm{Name: v.name, Label: v.label, Date: date, clientChannelPolicy: v.p})
		seen := map[int]bool{}
		for _, code := range []int{v.p.Latest, v.p.Minimum, v.p.Minimum - 1, 174} {
			if code <= 0 {
				continue
			}
			if seen[code] {
				continue
			}
			seen[code] = true
			p := decideClientRelease(c, v.name, code, now)
			result := "允许使用"
			if p.UpdateAvailable {
				result = "提醒更新"
			}
			if p.Blocked {
				result = "必须更新"
			}
			if p.Blocked && p.Retired {
				result = "结束测试，迁移正式版"
			}
			d.Preview = append(d.Preview, clientReleasePreview{v.label, code, result})
		}
	}
	p := decideClientRelease(c, "", 0, now)
	result := "不限制"
	if p.Blocked {
		result = "限制联网功能（包括无法识别的旧 Beta）"
	}
	d.Preview = append(d.Preview, clientReleasePreview{"无版本信息旧包", 0, result})
	return d
}
func parseClientReleaseForm(r *http.Request) (clientReleaseConfig, error) {
	var c clientReleaseConfig
	c.RejectLegacy = r.FormValue("reject_legacy") != ""
	for _, v := range []struct {
		name string
		p    *clientChannelPolicy
	}{{"stable", &c.Stable}, {"beta", &c.Beta}} {
		p := v.p
		p.Enabled = r.FormValue(v.name+"_enabled") != ""
		p.Retired = v.name == "beta" && r.FormValue("beta_retired") != ""
		for _, field := range []struct {
			name  string
			value *int
		}{{"minimum", &p.Minimum}, {"latest", &p.Latest}} {
			text := strings.TrimSpace(r.FormValue(v.name + "_" + field.name))
			if text == "" {
				text = "0"
			}
			value, err := strconv.Atoi(text)
			if err != nil {
				return c, errors.New("版本号格式不正确")
			}
			*field.value = value
		}
		p.DownloadURL = strings.TrimSpace(r.FormValue(v.name + "_url"))
		p.Message = strings.TrimSpace(r.FormValue(v.name + "_message"))
		if date := r.FormValue(v.name + "_date"); date != "" {
			t, err := time.ParseInLocation("2006-01-02T15:04", date, releaseBeijing)
			if err != nil {
				return c, errors.New("生效时间格式不正确")
			}
			p.ForceAfter = t.Unix()
		}
	}
	return c, validateClientReleaseConfig(c)
}
func (s *server) adminClientReleases(w http.ResponseWriter, r *http.Request) {
	pd, admin, allowed := s.adminPage(w, r, "版本管理", "system")
	if !allowed {
		return
	}
	_, sess := s.currentAdmin(r)
	c, err := readClientReleaseConfig(s.db)
	if err != nil {
		http.Error(w, "版本策略读取失败", 500)
		return
	}
	message := ""
	if r.Method == http.MethodPost {
		r.Body = http.MaxBytesReader(w, r.Body, 32*1024)
		if r.ParseForm() != nil || !csrfOK(sess, r) {
			http.Error(w, "表单或 CSRF 校验失败", 403)
			return
		}
		if admin.Role != "super" {
			http.Error(w, "只有超级管理员可以修改版本策略", 403)
			return
		}
		expected, parseErr := strconv.ParseInt(r.FormValue("revision"), 10, 64)
		action := r.FormValue("act")
		draft, parseErr2 := parseClientReleaseForm(r)
		if action == "disable" {
			draft = c
			draft.Stable.Enabled = false
			draft.Beta.Enabled = false
			draft.RejectLegacy = false
			parseErr2 = nil
		}
		if parseErr != nil {
			message = "页面版本信息无效，请刷新"
		} else if parseErr2 != nil {
			message = parseErr2.Error()
		} else if action == "preview" {
			draft.Revision = expected
			c = draft
		} else if action == "save" || action == "disable" {
			if err = saveClientReleaseConfig(s.db, admin.ID, draft, expected); err != nil {
				message = err.Error()
			} else {
				adminLog(s.db, r, admin.ID, "save_client_release_policy", "ios", fmt.Sprintf("stable=%t min=%d beta=%t retired=%t legacy=%t", draft.Stable.Enabled, draft.Stable.Minimum, draft.Beta.Enabled, draft.Beta.Retired, draft.RejectLegacy))
				redirectMsg(w, r, "/admin/client-releases", "版本策略已保存，客户端将在下次检查时获取", "")
				return
			}
		} else {
			message = "未知操作"
		}
	}
	data := clientReleasePageData(c, time.Now().Unix())
	data.CSRF = sess.csrf
	data.CanEdit = admin.Role == "super"
	data.Error = message
	pd.Data = data
	render(w, clientReleaseTemplate, pd)
}

var clientReleaseTemplate = mustTpl("client-releases", `{{with .Data}}
<div class="af-shell" style="max-width:1100px;padding:24px 0">
<div class="af-sec-hd"><div><h1 class="af-sec-t">版本管理</h1><p class="s12 af-t3 mt8">正式版与 Beta 独立控制。未启用时，不限制已有版本。</p></div><a class="af-btn af-btn-quiet" href="/admin/system">返回系统管理</a></div>
{{if .Error}}<p class="af-chip af-chip-danger mb16">{{.Error}}</p>{{end}}
<form method="post"><input type="hidden" name="_csrf" value="{{.CSRF}}"><input type="hidden" name="revision" value="{{.Revision}}">
<fieldset style="border:0;padding:0" {{if not .CanEdit}}disabled{{end}}>
<div class="gr gc1 gc2-md g16">
{{range .Channels}}<section class="af-glass" style="padding:20px"><h2 class="s18 mb16">{{.Label}}</h2>
<label class="f ic g8 mb16"><input type="checkbox" name="{{.Name}}_enabled" {{if .Enabled}}checked{{end}}>启用本渠道策略</label>
<div class="gr gc2 g12"><label class="af-label">最新发布编号<input class="af-input mt4" name="{{.Name}}_latest" type="number" min="0" max="1000000000" value="{{.Latest}}"></label>
<label class="af-label">最低可用编号<input class="af-input mt4" name="{{.Name}}_minimum" type="number" min="0" value="{{.Minimum}}"></label></div>
<label class="af-label mt12">强制生效时间（北京时间，留空立即）<input class="af-input mt4" type="datetime-local" name="{{.Name}}_date" value="{{.Date}}"></label>
<label class="af-label mt12">HTTPS 下载地址<input class="af-input mt4" name="{{.Name}}_url" type="url" value="{{.DownloadURL}}" placeholder="https://"></label>
<label class="af-label mt12">更新说明<textarea class="af-input mt4" name="{{.Name}}_message" maxlength="500" rows="3">{{.Message}}</textarea></label>
{{if eq .Name "beta"}}<label class="f ic g8 mt16"><input type="checkbox" name="beta_retired" {{if .Retired}}checked{{end}}>结束全部 Beta 测试，转为安装正式版</label><p class="s11 af-t3 mt8">下载地址填正式版入口。先导出工程，在正式版逐个导入并检查，最后删除 Beta；不会自动删除应用或工程。</p>{{end}}</section>{{end}}
</div>
<section class="af-glass mt16" style="padding:20px"><label class="f ic g8"><input type="checkbox" name="reject_legacy" {{if .RejectLegacy}}checked{{end}}>同时限制没有版本信息的旧客户端</label><p class="s11 af-t3 mt8">仅随正式版最低版本和生效时间执行；无法区分的旧 Beta 也会受影响。旧包只可限制已有联网功能，无法远程补出完整更新页面。</p></section>
<div class="f wrap g10 mt20"><button class="af-btn af-btn-quiet" name="act" value="preview">预览影响，不保存</button><button class="af-btn af-btn-primary" name="act" value="save">保存策略</button><button class="af-btn af-btn-quiet" name="act" value="disable">撤回全部限制</button></div></fieldset></form>
<section class="af-glass mt24" style="padding:20px"><h2 class="s16 mb12">当前表单的影响预览</h2><p class="s11 af-t3 mb12">按当前时间检查最新、最低、最低前一版及示例 r174；预览不会保存。编号对应猫鹤发布编号，不是 6.2.58 / 865。</p><table style="width:100%;text-align:left"><thead><tr><th>渠道</th><th>发布编号</th><th>处理方式</th></tr></thead><tbody>{{range .Preview}}<tr><td style="padding:10px 0">{{.Channel}}</td><td>{{.Code}}</td><td>{{.Result}}</td></tr>{{end}}</tbody></table></section>
</div>{{end}}`)

var legacyCrashSummaryLine = regexp.MustCompile(`^(异常退出|崩溃（信号）|崩溃（异常）|演示数据) · [0-9.]+ \([0-9]+\) · r[0-9]+ · (?:stable|beta) · [0-9a-f]{12}$`)

// 只清理旧客户端自动生成的摘要，不改用户自由填写的正文；附件保留内部诊断标识。
func clientReleaseCrashSummary(content, label string) string {
	lines := strings.Split(content, "\n")
	if len(lines) >= 3 && lines[0] == "用户在 App 内点击“发送日志”。" && lines[2] == "日志见附件。" {
		if match := legacyCrashSummaryLine.FindStringSubmatch(lines[1]); match != nil {
			lines[1] = match[1] + " · " + label
			return strings.Join(lines, "\n")
		}
	}
	return content
}

func clientReleaseTicketContent(content string, r *http.Request) string {
	if !strings.EqualFold(strings.TrimSpace(r.Header.Get("X-AM-Platform")), "ios") {
		return content
	}
	channel, code := clientReleaseIdentity(r)
	if code == 0 || (channel != "stable" && channel != "beta") {
		return content + "\n\n[客户端：版本未上报，可能为旧版]"
	}
	label := "猫鹤AM · 正式版"
	if channel == "beta" {
		label = "猫鹤AM · 测试版"
	}
	date := strings.TrimSpace(r.Header.Get("X-AM-Release-Date"))
	if parsed, err := time.Parse("20060102", date); err == nil && parsed.Format("20060102") == date {
		label = "猫鹤AM · " + date[4:] + " 正式版"
		if channel == "beta" {
			label = "猫鹤AM · " + date[4:] + " 测试版"
		}
	}
	return clientReleaseCrashSummary(content, label) + "\n\n[客户端：" + label + "]"
}
