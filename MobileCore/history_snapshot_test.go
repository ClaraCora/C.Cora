package mihomo

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/netip"
	"testing"
	"time"

	"github.com/gofrs/uuid/v5"
	"github.com/metacubex/mihomo/common/atomic"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func historyTestInfos(count int) []*statistic.TrackerInfo {
	infos := make([]*statistic.TrackerInfo, count)
	for i := range infos {
		infos[i] = &statistic.TrackerInfo{
			UUID: uuid.Must(uuid.FromString(fmt.Sprintf("00000000-0000-0000-0000-%012d", i))),
			Metadata: &C.Metadata{
				NetWork: C.TCP, Type: C.TUN,
				SrcIP: netip.MustParseAddr("192.0.2.1"), DstIP: netip.MustParseAddr("2001:db8::1"),
				SrcPort: 54321, DstPort: 443, Host: "例子.example.org", SniffHost: "example.org",
				Process: "process", ProcessPath: "/test/应用", DstGeoIP: []string{"US"},
				DstIPASN: "test ASN", InName: "tun", DNSMode: C.DNSNormal,
			},
			UploadTotal: atomic.NewInt64(1<<53 + 7), DownloadTotal: atomic.NewInt64(1<<53 + 9),
			Start: time.Date(2026, 9, 30, 12, 34, 56, 123456789, time.UTC),
			Chain: C.Chain{"节点\"一", "中间组", "策略"}, ProviderChain: C.Chain{"provider"},
			Rule: "DomainSuffix", RulePayload: "example.org",
		}
	}
	return infos
}

func TestHistoryProjectionPreservesPersistedFields(t *testing.T) {
	infos := historyTestInfos(3)
	infos[1].Metadata = nil
	infos[1].Chain = nil
	infos[2].Metadata = &C.Metadata{}
	projected := connectionHistoryRecords(infos)
	for i, info := range infos {
		original, err := json.Marshal(info)
		if err != nil {
			t.Fatal(err)
		}
		compact, err := json.Marshal(projected[i])
		if err != nil {
			t.Fatal(err)
		}
		var oldFields, newFields map[string]json.RawMessage
		if err := json.Unmarshal(original, &oldFields); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(compact, &newFields); err != nil {
			t.Fatal(err)
		}
		for _, key := range []string{"id", "upload", "download", "start", "chains", "rule", "rulePayload"} {
			if !bytes.Equal(oldFields[key], newFields[key]) {
				t.Errorf("record %d field %s changed: %s -> %s", i, key, oldFields[key], newFields[key])
			}
		}
		if info.Metadata == nil {
			if string(newFields["metadata"]) != "null" {
				t.Fatal("nil metadata changed")
			}
			continue
		}
		var oldMetadata, newMetadata map[string]json.RawMessage
		if err := json.Unmarshal(oldFields["metadata"], &oldMetadata); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(newFields["metadata"], &newMetadata); err != nil {
			t.Fatal(err)
		}
		for _, key := range []string{"network", "type", "sourceIP", "destinationIP", "sourcePort", "destinationPort", "host", "sniffHost", "process", "processPath"} {
			if !bytes.Equal(oldMetadata[key], newMetadata[key]) {
				t.Errorf("record %d metadata %s changed: %s -> %s", i, key, oldMetadata[key], newMetadata[key])
			}
		}
		if len(newMetadata) != 10 || len(newFields) != 8 {
			t.Fatal("history includes fields the store does not consume")
		}
	}
}

func TestHistorySnapshotEnvelopes(t *testing.T) {
	for _, payload := range [][]byte{ConnectionHistorySnapshot(256), ClosedConnectionHistorySnapshot(-1, 512)} {
		var snapshot struct {
			Connections []connectionHistoryRecord `json:"connections"`
		}
		if err := json.Unmarshal(payload, &snapshot); err != nil {
			t.Fatal(err)
		}
		if snapshot.Connections == nil {
			t.Fatal("empty connections must encode as [] for the Swift parser")
		}
	}
	var closed struct {
		Cursor  *uint64 `json:"cursor"`
		Dropped *bool   `json:"dropped"`
	}
	if err := json.Unmarshal(ClosedConnectionHistorySnapshot(0, 0), &closed); err != nil {
		t.Fatal(err)
	}
	if closed.Cursor == nil || closed.Dropped == nil {
		t.Fatal("close queue acknowledgement fields missing")
	}
}

var historyBenchmarkBytes []byte
var historyBenchmarkString string

func BenchmarkHistorySnapshotEncoding(b *testing.B) {
	for _, count := range []int{256, 512} {
		infos := historyTestInfos(count)
		b.Run(fmt.Sprintf("records=%d/original", count), func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				payload, err := json.Marshal(struct {
					Connections []*statistic.TrackerInfo `json:"connections"`
				}{infos})
				if err != nil {
					b.Fatal(err)
				}
				historyBenchmarkString = string(payload)
			}
			b.ReportMetric(float64(len(historyBenchmarkString)), "payload-B")
		})
		b.Run(fmt.Sprintf("records=%d/compact", count), func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				payload, err := json.Marshal(struct {
					Connections []connectionHistoryRecord `json:"connections"`
				}{connectionHistoryRecords(infos)})
				if err != nil {
					b.Fatal(err)
				}
				historyBenchmarkBytes = payload
			}
			b.ReportMetric(float64(len(historyBenchmarkBytes)), "payload-B")
		})
	}
}
