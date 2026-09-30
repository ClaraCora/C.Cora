package mihomo

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"net/url"
	"strconv"
	"time"

	http "github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/dialer"
)

const po0APIBase = "https://124.221.69.228/api/firewall/"
const po0MaximumResponseBytes = 32 << 10

func fetchPO0Whitelist(ctx context.Context, token po0Token) po0Result {
	tlsConfig, err := ca.GetTLSConfig(ca.Option{})
	if err != nil {
		return po0Result{Error: "无法初始化安全连接"}
	}
	transport := &http.Transport{
		// Bind directly to the physical interface, independent of proxy rules
		// and global mode. Otherwise the API would whitelist a proxy server.
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			return dialer.DialContext(ctx, "tcp4", address, dialer.WithInterface(currentPhysicalInterface()))
		},
		TLSClientConfig: tlsConfig, TLSHandshakeTimeout: 8 * time.Second,
		DisableKeepAlives: true, DisableCompression: true,
		MaxResponseHeaderBytes: 16 << 10,
	}
	defer transport.CloseIdleConnections()
	return requestPO0Whitelist(ctx, newPO0HTTPClient(transport), po0APIBase, token, 1500*time.Millisecond)
}

func newPO0HTTPClient(transport http.RoundTripper) *http.Client {
	return &http.Client{Transport: transport, Timeout: 15 * time.Second,
		// Never forward a token in the URL to a redirect destination.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func requestPO0Whitelist(ctx context.Context, client *http.Client, base string,
	token po0Token, backoff time.Duration) po0Result {
	endpoint := base + url.PathEscape(token.value) + "/add"
	if token.slot != nil {
		endpoint += "?slot=" + strconv.Itoa(*token.slot)
	}
	var result po0Result
	for attempt := 0; attempt < 3; attempt++ {
		if ctx.Err() != nil {
			return po0Result{Error: "检测已取消"}
		}
		if attempt > 0 {
			timer := time.NewTimer(time.Duration(attempt) * backoff)
			select {
			case <-ctx.Done():
				timer.Stop()
				return po0Result{Error: "检测已取消"}
			case <-timer.C:
			}
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, nil)
		if err != nil {
			return po0Result{Error: "请求地址无效"}
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json")
		req.Header.Set("User-Agent", "Cora/1.0 PO0Whitelist")
		resp, err := client.Do(req)
		if err != nil {
			// url.Error contains the credential-bearing URL: never surface it.
			result = po0Result{Error: "网络请求失败，请检查网络或服务器证书"}
			continue
		}
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, po0MaximumResponseBytes+1))
		resp.Body.Close()
		if len(body) > po0MaximumResponseBytes {
			return po0Result{Error: "服务器响应过大，请稍后重试"}
		}
		if readErr != nil {
			result = po0Result{Error: "读取响应失败"}
			continue
		}
		result = decodePO0Response(resp.StatusCode, body)
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return result
		}
		if resp.StatusCode == 403 || (resp.StatusCode < 500 && json.Valid(body)) {
			return result
		}
		// Match the reference's bounded retries for 5xx and bare transient errors.
	}
	return result
}

func decodePO0Response(status int, body []byte) po0Result {
	if status == 403 {
		return po0Result{Error: "请求被拒绝，请检查 Token；若为槽位冲突，请先在 PO0 网站删除旧槽位"}
	}
	if status < 200 || status >= 300 {
		return po0Result{Error: fmt.Sprintf("服务返回 HTTP %d，请检查 Token 或稍后重试", status)}
	}
	var payload struct {
		Enabled   *bool             `json:"enabled"`
		CurrentIP string            `json:"currentIp"`
		Whitelist []json.RawMessage `json:"whitelist"`
		Limit     int               `json:"limit"`
	}
	if json.Unmarshal(body, &payload) != nil || payload.Enabled == nil || payload.Whitelist == nil ||
		!validPO0Address(payload.CurrentIP) || payload.Limit < 0 {
		return po0Result{Error: "响应格式异常，请检查 Token 或稍后重试"}
	}
	result := po0Result{Enabled: *payload.Enabled, CurrentIP: payload.CurrentIP, Limit: payload.Limit,
		Whitelist: make([]po0Entry, 0, min(len(payload.Whitelist), 64))}
	for _, raw := range payload.Whitelist {
		var entry po0Entry
		if json.Unmarshal(raw, &entry) != nil {
			if json.Unmarshal(raw, &entry.IP) != nil {
				return po0Result{Error: "白名单格式异常"}
			}
		}
		if !validPO0Address(entry.IP) {
			return po0Result{Error: "白名单地址格式异常"}
		}
		result.Applied = result.Applied || (result.Enabled && samePO0Network(entry.IP, result.CurrentIP))
		if len(result.Whitelist) < 64 {
			result.Whitelist = append(result.Whitelist, entry)
		} else {
			result.Truncated = true
		}
	}
	return result
}

func validPO0Address(value string) bool {
	if ip, err := netip.ParseAddr(value); err == nil {
		return ip.Is4()
	}
	prefix, err := netip.ParsePrefix(value)
	return err == nil && prefix.Addr().Is4() && prefix.Bits() == 24
}

func samePO0Network(a, b string) bool {
	if !validPO0Address(a) || !validPO0Address(b) {
		return false
	}
	if a == b {
		return true
	}
	pa, ea := netip.ParsePrefix(a)
	pb, eb := netip.ParsePrefix(b)
	if ea != nil && eb != nil {
		return false
	}
	ipA, _ := netip.ParseAddr(a)
	ipB, _ := netip.ParseAddr(b)
	if ea == nil {
		ipA = pa.Addr()
	}
	if eb == nil {
		ipB = pb.Addr()
	}
	return netip.PrefixFrom(ipA, 24).Masked() == netip.PrefixFrom(ipB, 24).Masked()
}
