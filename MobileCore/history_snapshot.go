package mihomo

import (
	"encoding/json"
	"net/netip"
	"sync/atomic"
	"time"

	"github.com/gofrs/uuid/v5"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// History needs only the fields consumed by ConnectionHistoryRecord. In
// particular, geo/ASN/inbound/provider-chain data must not create an unused
// Foundation object graph in the Network Extension every two seconds.
type connectionHistoryMetadata struct {
	Network         string     `json:"network"`
	Type            string     `json:"type"`
	SourceIP        netip.Addr `json:"sourceIP"`
	DestinationIP   netip.Addr `json:"destinationIP"`
	SourcePort      uint16     `json:"sourcePort,string"`
	DestinationPort uint16     `json:"destinationPort,string"`
	Host            string     `json:"host"`
	SniffHost       string     `json:"sniffHost"`
	Process         string     `json:"process"`
	ProcessPath     string     `json:"processPath"`
}

type connectionHistoryRecord struct {
	ID          uuid.UUID                  `json:"id"`
	Metadata    *connectionHistoryMetadata `json:"metadata"`
	Upload      int64                      `json:"upload"`
	Download    int64                      `json:"download"`
	Start       time.Time                  `json:"start"`
	Chains      C.Chain                    `json:"chains"`
	Rule        string                     `json:"rule"`
	RulePayload string                     `json:"rulePayload"`
}

func connectionHistoryRecords(infos []*statistic.TrackerInfo) []connectionHistoryRecord {
	records := make([]connectionHistoryRecord, 0, len(infos))
	for _, info := range infos {
		if info == nil {
			continue
		}
		record := connectionHistoryRecord{
			ID: info.UUID, Upload: info.UploadTotal.Load(), Download: info.DownloadTotal.Load(),
			Start: info.Start, Chains: info.Chain, Rule: info.Rule, RulePayload: info.RulePayload,
		}
		if metadata := info.Metadata; metadata != nil {
			record.Metadata = &connectionHistoryMetadata{
				Network: metadata.NetWork.String(), Type: metadata.Type.String(),
				SourceIP: metadata.SrcIP, DestinationIP: metadata.DstIP,
				SourcePort: metadata.SrcPort, DestinationPort: metadata.DstPort,
				Host: metadata.Host, SniffHost: metadata.SniffHost,
				Process: metadata.Process, ProcessPath: metadata.ProcessPath,
			}
		}
		records = append(records, record)
	}
	return records
}

// ConnectionHistorySnapshot returns the NE recorder's active sample as NSData
// through gomobile, avoiding the Go string -> NSString -> UTF-8 Data round trip.
// The App's richer ConnectionsSnapshot IPC response remains separate.
func ConnectionHistorySnapshot(limit int) []byte {
	if limit < 1 {
		limit = defaultConnectionSnapshotLimit
	} else if limit > maxConnectionSnapshotLimit {
		limit = maxConnectionSnapshotLimit
	}
	connections, total := newestConnectionSnapshot(limit)
	out, err := json.Marshal(struct {
		Connections []connectionHistoryRecord `json:"connections"`
		Truncated   bool                      `json:"truncated"`
	}{connectionHistoryRecords(connections), total > len(connections)})
	if err != nil {
		return nil
	}
	atomic.StoreInt64(&lastConnectionSnapshotBytes, int64(len(out)))
	return out
}

// ClosedConnectionHistorySnapshot preserves the close queue's acknowledgement
// protocol while returning only persisted fields directly as NSData.
func ClosedConnectionHistorySnapshot(cursor int64, limit int) []byte {
	if cursor < 0 {
		cursor = 0
	}
	if limit < 1 {
		limit = 1
	} else if limit > 512 {
		limit = 512
	}
	next, dropped, connections := statistic.DefaultManager.ClosedSince(uint64(cursor), limit)
	out, err := json.Marshal(struct {
		Cursor      uint64                    `json:"cursor"`
		Dropped     bool                      `json:"dropped"`
		Connections []connectionHistoryRecord `json:"connections"`
	}{next, dropped, connectionHistoryRecords(connections)})
	if err != nil {
		return nil
	}
	atomic.StoreInt64(&lastClosedSnapshotBytes, int64(len(out)))
	return out
}
