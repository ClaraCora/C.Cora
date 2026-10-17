package mihomo

import (
	"encoding/json"
	"errors"

	"github.com/metacubex/mihomo/component/iosupdate"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type iosUpdateBlockConfiguration struct {
	ID      string `json:"id"`
	Enabled bool   `json:"enabled"`
}

func (c iosUpdateBlockConfiguration) valid() bool {
	if len(c.ID) == 0 || len(c.ID) > 64 {
		return false
	}
	for _, ch := range c.ID {
		if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-') {
			return false
		}
	}
	return true
}

func IOSUpdateBlockStatusData() []byte {
	data, _ := json.Marshal(iosupdate.Status())
	return data
}

func IOSUpdateBlockStatus() string { return string(IOSUpdateBlockStatusData()) }

// ConfigureIOSUpdateBlockData is independent of ordinary connection settings;
// hot toggles do not reapply configuration or cancel other control-plane work.
func ConfigureIOSUpdateBlockData(configurationJSON string) []byte {
	var value iosUpdateBlockConfiguration
	if len(configurationJSON) > 512 || json.Unmarshal([]byte(configurationJSON), &value) != nil || !value.valid() {
		return []byte(`{"error":"iOS 更新拦截设置格式不正确"}`)
	}
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	if coreSessionClock == nil || !iosupdate.Configure(value.ID, value.Enabled) {
		return []byte(`{"error":"VPN 尚未连接，请稍后重试"}`)
	}
	if value.Enabled {
		// Do not serialize the connection catalog or close unrelated traffic.
		statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
			info := tracker.Info()
			if info != nil && info.Metadata != nil &&
				(iosupdate.Matches(info.Metadata.Host) || iosupdate.Matches(info.Metadata.SniffHost)) {
				_ = tracker.Close()
			}
			return true
		})
	}
	return IOSUpdateBlockStatusData()
}

func ConfigureIOSUpdateBlock(configurationJSON string) string {
	return string(ConfigureIOSUpdateBlockData(configurationJSON))
}

func ResetIOSUpdateBlockStatsData() []byte {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	if coreSessionClock == nil {
		return []byte(`{"error":"VPN 尚未连接，请稍后重试"}`)
	}
	iosupdate.ResetStats()
	return IOSUpdateBlockStatusData()
}

func ResetIOSUpdateBlockStats() string { return string(ResetIOSUpdateBlockStatsData()) }

func validateIOSUpdateBlockConfiguration(st appSettings) error {
	if !st.IOSUpdateBlock.valid() {
		return errors.New("iOS 更新拦截设置格式不正确")
	}
	return nil
}
