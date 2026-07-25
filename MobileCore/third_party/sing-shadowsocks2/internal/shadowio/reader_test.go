package shadowio

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"io"
	"strconv"
	"sync"
	"testing"

	N "github.com/metacubex/sing/common/network"
)

var testCipherKey = [16]byte{
	0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
	0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
}

func newTestAEAD(t testing.TB) cipher.AEAD {
	t.Helper()
	block, err := aes.NewCipher(testCipherKey[:])
	if err != nil {
		t.Fatal(err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	return aead
}

func testPayload(size int, seed byte) []byte {
	payload := make([]byte, size)
	for i := range payload {
		payload[i] = seed + byte(i*31)
	}
	return payload
}

func encryptTestRecords(t testing.TB, payloads ...[]byte) []byte {
	t.Helper()
	aead := newTestAEAD(t)
	nonce := make([]byte, aead.NonceSize())
	var wire []byte
	for _, payload := range payloads {
		if len(payload) > maxManagedBufferSize {
			t.Fatalf("payload length %d exceeds SS2022 maximum", len(payload))
		}
		var length [PacketLengthBufferSize]byte
		binary.BigEndian.PutUint16(length[:], uint16(len(payload)))
		wire = aead.Seal(wire, nonce, length[:], nil)
		increaseNonce(nonce)
		wire = aead.Seal(wire, nonce, payload, nil)
		increaseNonce(nonce)
	}
	return wire
}

func readWaitPayload(t testing.TB, reader *Reader, size int) []byte {
	t.Helper()
	decoded := make([]byte, 0, size)
	for len(decoded) < size {
		buffer, err := reader.WaitReadBuffer()
		if err != nil {
			t.Fatalf("WaitReadBuffer: %v", err)
		}
		if buffer == nil || buffer.IsEmpty() {
			if buffer != nil {
				buffer.Release()
			}
			t.Fatal("WaitReadBuffer returned an empty buffer")
		}
		if len(decoded)+buffer.Len() > size {
			buffer.Release()
			t.Fatalf("decoded payload exceeds expected size %d", size)
		}
		decoded = append(decoded, buffer.Bytes()...)
		buffer.Release()
	}
	return decoded
}

func TestReaderRecordSizeBoundary(t *testing.T) {
	for _, size := range []int{
		maxManagedBufferSize - Overhead,
		maxManagedBufferSize - Overhead + 1,
		maxManagedBufferSize,
	} {
		t.Run(strconv.Itoa(size), func(t *testing.T) {
			payload := testPayload(size, byte(size))
			reader := NewReader(bytes.NewReader(encryptTestRecords(t, payload)), newTestAEAD(t))

			decoded := readWaitPayload(t, reader, len(payload))
			if !bytes.Equal(decoded, payload) {
				t.Fatalf("decoded payload mismatch for size %d", size)
			}
		})
	}
}

func TestReaderOversizedBuffersDoNotAlias(t *testing.T) {
	firstPayload := testPayload(maxManagedBufferSize, 0x11)
	secondPayload := testPayload(maxManagedBufferSize, 0x82)
	reader := NewReader(
		bytes.NewReader(encryptTestRecords(t, firstPayload, secondPayload)),
		newTestAEAD(t),
	)

	first, err := reader.WaitReadBuffer()
	if err != nil {
		t.Fatalf("read first record: %v", err)
	}
	defer first.Release()
	firstSnapshot := append([]byte(nil), first.Bytes()...)
	if !bytes.Equal(first.Bytes(), firstPayload[:first.Len()]) {
		t.Fatal("first decoded payload prefix mismatch")
	}
	remainingFirst := readWaitPayload(t, reader, len(firstPayload)-first.Len())
	if !bytes.Equal(remainingFirst, firstPayload[first.Len():]) {
		t.Fatal("first decoded payload remainder mismatch")
	}

	second, err := reader.WaitReadBuffer()
	if err != nil {
		t.Fatalf("read second record: %v", err)
	}
	defer second.Release()

	if !bytes.Equal(first.Bytes(), firstSnapshot) {
		t.Fatal("reading the second record mutated the first returned buffer")
	}
	if !bytes.Equal(second.Bytes(), secondPayload[:second.Len()]) {
		t.Fatal("second decoded payload prefix mismatch")
	}
}

func TestReaderReusesOversizedBuffer(t *testing.T) {
	firstPayload := testPayload(maxManagedBufferSize, 0x29)
	secondPayload := testPayload(maxManagedBufferSize, 0x73)
	reader := NewReader(
		bytes.NewReader(encryptTestRecords(t, firstPayload, secondPayload)),
		newTestAEAD(t),
	)
	decoded := make([]byte, maxManagedBufferSize)

	if _, err := io.ReadFull(reader, decoded); err != nil {
		t.Fatalf("read first record: %v", err)
	}
	if !bytes.Equal(decoded, firstPayload) {
		t.Fatal("first decoded payload mismatch")
	}
	firstBuffer := &reader.oversizedBuffer[0]

	if _, err := io.ReadFull(reader, decoded); err != nil {
		t.Fatalf("read second record: %v", err)
	}
	if !bytes.Equal(decoded, secondPayload) {
		t.Fatal("second decoded payload mismatch")
	}
	if firstBuffer != &reader.oversizedBuffer[0] {
		t.Fatal("oversized record allocated a new backing buffer")
	}
}

func TestReaderZeroLengthReadPreservesOversizedRecord(t *testing.T) {
	payload := testPayload(maxManagedBufferSize, 0x31)
	reader := NewReader(bytes.NewReader(encryptTestRecords(t, payload)), newTestAEAD(t))

	n, err := reader.Read(nil)
	if err != nil || n != 0 {
		t.Fatalf("zero-length Read = (%d, %v), want (0, nil)", n, err)
	}
	decoded := make([]byte, len(payload))
	if _, err = io.ReadFull(reader, decoded); err != nil {
		t.Fatalf("read record after zero-length Read: %v", err)
	}
	if !bytes.Equal(decoded, payload) {
		t.Fatal("zero-length Read changed the next record")
	}
}

func TestReaderCloseReleasesOversizedBuffer(t *testing.T) {
	payload := testPayload(maxManagedBufferSize, 0x35)
	reader := NewReader(bytes.NewReader(encryptTestRecords(t, payload)), newTestAEAD(t))
	buffer, err := reader.WaitReadBuffer()
	if err != nil {
		t.Fatalf("WaitReadBuffer: %v", err)
	}
	buffer.Release()
	if reader.oversizedBuffer == nil || reader.oversizedCached == 0 {
		t.Fatal("test did not leave a partially consumed oversized record")
	}

	if err := reader.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if reader.oversizedBuffer != nil || reader.oversizedIndex != 0 || reader.oversizedCached != 0 {
		t.Fatal("Close retained the oversized record buffer")
	}
	if err := reader.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
}

type fragmentedReader struct {
	reader io.Reader
	limit  int
}

func (r *fragmentedReader) Read(p []byte) (int, error) {
	if len(p) > r.limit {
		p = p[:r.limit]
	}
	return r.reader.Read(p)
}

func TestReaderOversizedRecordFromFragmentedTransport(t *testing.T) {
	payload := testPayload(maxManagedBufferSize, 0x3c)
	upstream := &fragmentedReader{
		reader: bytes.NewReader(encryptTestRecords(t, payload)),
		limit:  7,
	}
	reader := NewReader(upstream, newTestAEAD(t))

	decoded, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if !bytes.Equal(decoded, payload) {
		t.Fatal("decoded fragmented payload mismatch")
	}
}

func TestReaderOversizedRecordWithReadWaitHeadroom(t *testing.T) {
	payload := testPayload(maxManagedBufferSize, 0x46)
	reader := NewReader(bytes.NewReader(encryptTestRecords(t, payload)), newTestAEAD(t))
	options := N.ReadWaitOptions{
		FrontHeadroom: 8,
		RearHeadroom:  16,
		MTU:           1500,
	}
	if !reader.InitializeReadWaiter(options) {
		t.Fatal("reader did not request the required headroom copy")
	}

	decoded := make([]byte, 0, len(payload))
	for len(decoded) < len(payload) {
		buffer, err := reader.WaitReadBuffer()
		if err != nil {
			t.Fatalf("WaitReadBuffer: %v", err)
		}
		if buffer.Start() != options.FrontHeadroom {
			buffer.Release()
			t.Fatalf("front headroom = %d, want %d", buffer.Start(), options.FrontHeadroom)
		}
		if buffer.Len() > options.MTU {
			buffer.Release()
			t.Fatalf("returned %d bytes, MTU is %d", buffer.Len(), options.MTU)
		}
		decoded = append(decoded, buffer.Bytes()...)
		buffer.Release()
	}
	if !bytes.Equal(decoded, payload) {
		t.Fatal("decoded headroom payload mismatch")
	}
}

func TestReaderRejectsInvalidOversizedRecord(t *testing.T) {
	payload := testPayload(maxManagedBufferSize, 0x4d)
	validWire := encryptTestRecords(t, payload)
	tests := map[string][]byte{
		"truncated": validWire[:len(validWire)-1],
		"tampered":  append([]byte(nil), validWire...),
	}
	tests["tampered"][len(tests["tampered"])-1] ^= 0x80

	for name, wire := range tests {
		t.Run(name, func(t *testing.T) {
			reader := NewReader(bytes.NewReader(wire), newTestAEAD(t))
			buffer, err := reader.WaitReadBuffer()
			if err == nil {
				if buffer != nil {
					buffer.Release()
				}
				t.Fatal("invalid record was accepted")
			}
			if buffer != nil {
				buffer.Release()
				t.Fatal("invalid record returned a buffer")
			}

			validReader := NewReader(bytes.NewReader(validWire), newTestAEAD(t))
			decoded := readWaitPayload(t, validReader, len(payload))
			if !bytes.Equal(decoded, payload) {
				t.Fatal("decoded payload mismatch after error recovery")
			}
		})
	}
}

func TestReaderOversizedRecordReuseIsConcurrent(t *testing.T) {
	payload := testPayload(maxManagedBufferSize, 0x5e)
	wire := encryptTestRecords(t, payload)

	const readers = 16
	aeads := make([]cipher.AEAD, readers)
	for i := range aeads {
		aeads[i] = newTestAEAD(t)
	}
	var waitGroup sync.WaitGroup
	waitGroup.Add(readers)
	for i := 0; i < readers; i++ {
		go func(aead cipher.AEAD) {
			defer waitGroup.Done()
			reader := NewReader(bytes.NewReader(wire), aead)
			decoded, err := io.ReadAll(reader)
			if err != nil {
				t.Errorf("ReadAll: %v", err)
				return
			}
			if !bytes.Equal(decoded, payload) {
				t.Error("decoded concurrent payload mismatch")
			}
		}(aeads[i])
	}
	waitGroup.Wait()
}

func BenchmarkReaderMaxRecordReuse(b *testing.B) {
	const recordsPerIteration = 64
	payload := testPayload(maxManagedBufferSize, 0x6f)
	payloads := make([][]byte, recordsPerIteration)
	for i := range payloads {
		payloads[i] = payload
	}
	wire := encryptTestRecords(b, payloads...)
	aead := newTestAEAD(b)
	decoded := make([]byte, len(payload))
	b.SetBytes(int64(recordsPerIteration * len(payload)))
	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		reader := NewReader(bytes.NewReader(wire), aead)
		for j := 0; j < recordsPerIteration; j++ {
			if _, err := io.ReadFull(reader, decoded); err != nil {
				b.Fatal(err)
			}
		}
		_ = reader.Close()
	}
}
