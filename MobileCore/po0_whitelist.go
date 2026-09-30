package mihomo

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// A single sleeping worker owns automatic checks. No JS runtime, connection
// history or HTTP connection pool is retained between checks.
type po0Configuration struct {
	ID              string `json:"id"`
	Enabled         bool   `json:"enabled"`
	Tokens          string `json:"tokens"`
	IntervalMinutes int    `json:"intervalMinutes"`
}

type po0Token struct {
	value string
	slot  *int
}

type po0Entry struct {
	IP   string `json:"ip"`
	Slot *int   `json:"slot,omitempty"`
}

type po0Result struct {
	Index     int        `json:"index"`
	Slot      *int       `json:"slot,omitempty"`
	Enabled   bool       `json:"enabled"`
	Applied   bool       `json:"applied"`
	CurrentIP string     `json:"currentIp"`
	Whitelist []po0Entry `json:"whitelist"`
	Limit     int        `json:"limit"`
	Truncated bool       `json:"truncated"`
	Error     string     `json:"error,omitempty"`
}

type po0Snapshot struct {
	ConfigurationID string      `json:"configurationID"`
	Enabled         bool        `json:"enabled"`
	Checking        bool        `json:"checking"`
	Pending         bool        `json:"pending"`
	LastCheckedAt   int64       `json:"lastCheckedAt"`
	NextCheckAt     int64       `json:"nextCheckAt"`
	Results         []po0Result `json:"results"`
}

var po0TokenPattern = regexp.MustCompile(`^pgnfw_[A-Za-z0-9_-]{1,256}$`)

func parsePO0Configuration(raw string) (po0Configuration, []po0Token, error) {
	var cfg po0Configuration
	if len(raw) > 4096 || json.Unmarshal([]byte(raw), &cfg) != nil || cfg.ID == "" || len(cfg.ID) > 64 {
		return cfg, nil, errors.New("PO0 设置格式不正确，请重新保存")
	}
	switch cfg.IntervalMinutes {
	case 1, 3, 5, 10, 15, 30, 60:
	default:
		return cfg, nil, errors.New("请选择有效的检测频率")
	}
	parts := strings.FieldsFunc(cfg.Tokens, func(r rune) bool {
		return strings.ContainsRune(",|;、； \t\r\n", r)
	})
	if len(parts) > 8 {
		return cfg, nil, errors.New("最多配置 8 个 Token")
	}
	seen := make(map[string]bool, len(parts))
	tokens := make([]po0Token, 0, len(parts))
	for _, part := range parts {
		pair := strings.Split(part, "@")
		if len(pair) > 2 || !po0TokenPattern.MatchString(pair[0]) {
			return cfg, nil, errors.New("Token 应以 pgnfw_ 开头，可在末尾添加 @槽位")
		}
		item := po0Token{value: pair[0]}
		if len(pair) == 2 {
			slot, err := strconv.Atoi(pair[1])
			if err != nil || slot < 0 || slot > 65535 || strconv.Itoa(slot) != pair[1] {
				return cfg, nil, errors.New("槽位应为 0 至 65535 的整数")
			}
			item.slot = &slot
		}
		if seen[item.value] {
			return cfg, nil, errors.New("同一个 Token 只能配置一次")
		}
		seen[item.value] = true
		tokens = append(tokens, item)
	}
	if cfg.Enabled && len(tokens) == 0 {
		return cfg, nil, errors.New("请先填写 PO0 Token")
	}
	return cfg, tokens, nil
}

type po0Run struct {
	cancel context.CancelFunc
	done   chan struct{}
	wake   chan struct{}
}

type po0Service struct {
	control sync.Mutex
	mu      sync.Mutex
	run     *po0Run
	state   po0Snapshot
	fetch   func(context.Context, po0Token) po0Result
	// Kept configurable internally for deterministic, fast lifecycle tests.
	initialDelay time.Duration
	minimumGap   time.Duration
	intervalUnit time.Duration
}

func newPO0Service(fetch func(context.Context, po0Token) po0Result) *po0Service {
	return &po0Service{fetch: fetch, initialDelay: 2 * time.Second,
		minimumGap: 10 * time.Second, intervalUnit: time.Minute}
}

var po0Whitelist = newPO0Service(fetchPO0Whitelist)

func (s *po0Service) configure(raw string) error {
	cfg, tokens, err := parsePO0Configuration(raw)
	if err != nil {
		return err
	}
	s.control.Lock()
	defer s.control.Unlock()
	s.stopWorker()
	s.mu.Lock()
	s.state = po0Snapshot{ConfigurationID: cfg.ID, Enabled: cfg.Enabled, Results: []po0Result{}}
	if !cfg.Enabled {
		s.mu.Unlock()
		return nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	run := &po0Run{cancel: cancel, done: make(chan struct{}), wake: make(chan struct{}, 1)}
	s.run = run
	s.state.Pending = true
	s.state.NextCheckAt = time.Now().Add(s.initialDelay).Unix()
	s.mu.Unlock()
	go s.work(ctx, run, cfg, tokens)
	return nil
}

// control must be held. Cancellation also aborts requests and retry backoffs;
// joining the old worker prevents overlapping checks after token/interval edits.
func (s *po0Service) stopWorker() {
	s.mu.Lock()
	run := s.run
	s.run = nil
	s.mu.Unlock()
	if run != nil {
		run.cancel()
		<-run.done
	}
}

func (s *po0Service) stop() {
	s.control.Lock()
	defer s.control.Unlock()
	s.stopWorker()
	s.mu.Lock()
	s.state = po0Snapshot{Results: []po0Result{}}
	s.mu.Unlock()
}

func (s *po0Service) request(networkChange bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.run == nil || (!networkChange && (s.state.Checking || s.state.Pending)) {
		return
	}
	s.state.Pending = true
	select {
	case s.run.wake <- struct{}{}:
	default:
	}
}

func (s *po0Service) snapshotJSON() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, _ := json.Marshal(s.state)
	return string(data)
}

func (s *po0Service) work(ctx context.Context, run *po0Run, cfg po0Configuration, tokens []po0Token) {
	defer close(run.done)
	timer := time.NewTimer(s.initialDelay)
	defer timer.Stop()
	var lastStart time.Time
	for {
		select {
		case <-ctx.Done():
			return
		case <-run.wake:
			// Coalesce network flaps/manual taps. A path change during a request
			// gets one follow-up on the new path, never another concurrent worker.
			delay := max(s.initialDelay, time.Until(lastStart.Add(s.minimumGap)))
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(delay)
			s.mu.Lock()
			s.state.NextCheckAt = time.Now().Add(delay).Unix()
			s.mu.Unlock()
		case <-timer.C:
			if ctx.Err() != nil {
				return
			}
			lastStart = time.Now()
			s.mu.Lock()
			s.state.Checking, s.state.Pending = true, false
			s.state.NextCheckAt = 0
			s.mu.Unlock()
			results := make([]po0Result, 0, len(tokens))
			for i, token := range tokens {
				if ctx.Err() != nil {
					return
				}
				result := s.fetch(ctx, token)
				result.Index, result.Slot = i+1, token.slot
				if result.Whitelist == nil {
					result.Whitelist = []po0Entry{}
				}
				results = append(results, result)
			}
			if ctx.Err() != nil {
				return
			}
			delay := time.Duration(cfg.IntervalMinutes) * s.intervalUnit
			s.mu.Lock()
			s.state.Checking = false
			s.state.Results = results
			s.state.LastCheckedAt = time.Now().Unix()
			s.state.NextCheckAt = time.Now().Add(delay).Unix()
			s.mu.Unlock()
			timer.Reset(delay)
		}
	}
}

// ConfigurePO0Whitelist starts/stops a VPN-session-scoped background service.
// The returned state and errors never include credentials or request URLs.
func ConfigurePO0Whitelist(configurationJSON string) string {
	if err := po0Whitelist.configure(configurationJSON); err != nil {
		data, _ := json.Marshal(map[string]string{"error": err.Error()})
		return string(data)
	}
	return PO0WhitelistStatus()
}

func PO0WhitelistStatus() string { return po0Whitelist.snapshotJSON() }

func CheckPO0WhitelistNow() string {
	po0Whitelist.request(false)
	return PO0WhitelistStatus()
}
